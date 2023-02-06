# frozen_string_literal: true

require 'bundler/inline'

gemfile(true) do
  gem 'rails', '~> 7.0'
  gem 'sqlite3'
end

require 'active_record'
require 'action_controller/railtie'
require 'logger'
require 'json'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
# ActiveRecord::Base.logger = Logger.new($stdout)

class TestApp < Rails::Application
  config.root = __dir__
  config.hosts << 'example.org'
  secrets.secret_key_base = '93f17fcbb39e83aea9cee3833d684017775a7a57a23e8dd4baf86dcac3e0b69b85cd4a453f4e805e6a2edc13b5f763fb88b88f2cb8d337ad6c5dd62305f7779d'

  config.logger = Logger.new($stdout)
  Rails.logger  = config.logger

  routes.draw do
    resources :posts do
      resources :comments
    end
    resources :comments
  end
end

ActiveRecord::Schema.define do
  create_table :posts, force: true do |t|
    t.text :content
    t.integer :comments_count, default: 0
    t.timestamps
  end

  create_table :comments, force: true do |t|
    t.integer :post_id
    t.string :author
    t.text :content
  end

  add_index "posts", ["comments_count"], name: "index_posts_on_comments_count", using: :btree
end

class Post < ActiveRecord::Base
  has_many :comments, dependent: :destroy
  validates :content, presence: true
end

class Comment < ActiveRecord::Base
  belongs_to :post, counter_cache: true

  validates :content, length: { maximum: 500 }
  validates :author, presence: true
end

# Post.create!(content: 'lorem ipsum dolor quet sit amet consectetur adipiscing elit '* 25)
class PostsController < ActionController::Base
  def index
    render json: Post.all.to_json
  end

  def show
    render json: Post.find(params[:id]).to_json(include: :comments)
  end

  def create
    @post = Post.new(post_params)

    if @post.save
      render json: { post: @post, success: true, message: "Post saved successfully" }, status: :created
    else
      render json: { post: @post, success: false, message: "Post could not be saved" }, status: :unprocessable_entity
    end
  end

  private

  def post_params
    params.require(:post).permit(:content)
  end
end

class CommentsController < ActionController::Base
  def index
    post = Post.find(params[:post_id])
    comments = post.comments

    render json: comments
  end

  def show
    render json: Comment.find(params[:id])
  end

  def create
    @post = Post.find(params[:post_id])
    @post.with_lock do
      @comment = @post.comments.build(comment_params)

      if @comment.save
        render json: @comment , status: :ok
      else
        render json: { comment: @comment, success: false, message: "Comment could not be saved. Errors: #{@comment.errors}" }, status: :unprocessable_entity
      end
    end
  end

  def update
    @post = Post.find(params[:post_id])
    @post.with_lock do
      @comment = Comment.find(params[:id])

      if @comment.update(comment_params)
        render json: @comment, status: :ok
      else
        render json: @comment.errors, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @post = Post.find(params[:post_id])
    @post.with_lock do
      @comment = Comment.find(params[:id])

      if @comment.destroy
        render json: nil, status: :no_content
      else
        render json: @comment.errors, status: :unprocessable_entity
      end
    end
  end

  private

  def comment_params
    params.require(:comment).permit(:author, :content)
  end
end

# Tests code
require 'minitest/autorun'
require 'rack/test'

class ControllerTest < Minitest::Test
  include Rack::Test::Methods
  include Rails.application.routes.url_helpers

  private

  def json_response
    JSON.parse(last_response.body, symbolize_names: true)
  end

  def app
    Rails.application
  end
end

class CommentTest < Minitest::Test
  def test_association_stuff
    post = Post.create!(content: 'Hello Tests')
    post.comments << Comment.create!(author: "joe.doe", content: 'A comment')

    assert_equal 1, post.comments.count
    assert_equal 1, Comment.count
    assert_equal post.id, Comment.first.post.id
  end
end

class PostsControllerTest < ControllerTest
  def setup
    @post = Post.create!(content: 'Test: lorem ipsum dolor quet sit amet')
  end

  def teardown
    @post.destroy
  end
 
  def test_successful_index_request
    get posts_path(only_path: true)
    assert last_response.ok?
    assert_equal 'application/json; charset=utf-8', last_response.content_type
    assert_equal Post.count, json_response.count
  end

  def test_successful_show_request
    get post_path(@post, only_path: true)
    assert last_response.ok?
    assert_equal 'application/json; charset=utf-8', last_response.content_type
    assert_equal "Test: lorem ipsum dolor quet sit amet", json_response[:content]
  end
end

class ComentsControllerTest < ControllerTest
  def setup
    @post = Post.create!(content: 'Another Test: lorem ipsum dolor quet sit amet')
    @post.comments << Comment.create!(author: 'jane.doe', content: 'An awesome comment')
  end

  def teardown
    @post.destroy
  end
 
  def test_successful_index_request
    get post_comments_path(@post, only_path: true)
    assert last_response.ok?
    assert_equal 'application/json; charset=utf-8', last_response.content_type
    assert_equal @post.comments.count, json_response.count
  end

  def test_successful_show_request
    get post_comment_url(@post, @post.comments.first, only_path: true)
    assert last_response.ok?
    assert_equal 'application/json; charset=utf-8', last_response.content_type
    assert_equal "jane.doe", json_response[:author]
    assert_equal "An awesome comment", json_response[:content]
  end

  def test_successful_create_request
    before_coments_count = @post.comments_count
    post post_comments_url(@post, only_path: true), comment: { author: 'joe.doe', content: 'A new comment' }
    assert last_response.ok?
    assert_equal 'application/json; charset=utf-8', last_response.content_type
    assert_equal "joe.doe", json_response[:author]
    assert_equal "A new comment", json_response[:content]
    assert_equal before_coments_count + 1, @post.reload.comments_count
  end

  def test_successful_update_request
    patch post_comment_url(@post, @post.comments.first, only_path: true), comment: { content: 'An updated comment' }
    assert last_response.ok?
    assert_equal 'application/json; charset=utf-8', last_response.content_type
    assert_equal "jane.doe", json_response[:author]
    assert_equal "An updated comment", json_response[:content]
  end

  def test_successful_destroy_request
    delete post_comment_url(@post, @post.comments.first, only_path: true)
    assert_equal 204, last_response.status
  end
end