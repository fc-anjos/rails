# frozen_string_literal: true

require "fileutils"
require "abstract_unit"
require "lib/controller/fake_models"
require "active_support/testing/ractors_assertions"
require "active_support/core_ext/object/with"

CACHE_DIR = "test_cache"
# Don't change '/../temp/' cavalierly or you might hose something you don't want hosed
FILE_STORE_PATH = File.join(__dir__, "../temp/", CACHE_DIR)

class FragmentCachingMetalTestController < ActionController::Metal
  abstract!

  include ActionController::Caching

  def some_action; end
end

class FragmentCachingMetalTest < ActionController::TestCase
  def setup
    super
    @store = ActiveSupport::Cache::MemoryStore.new
    @controller = FragmentCachingMetalTestController.new
    @controller.perform_caching = true
    @controller.cache_store = @store
    @params = { controller: "posts", action: "index" }
    @controller.params = @params
    @controller.request = @request
    @controller.response = @response
  end
end

class CachingController < ActionController::Base
  abstract!

  self.cache_store = :file_store, FILE_STORE_PATH
end

class FragmentCachingTestController < CachingController
  def some_action; end
end

class FragmentCachingTest < ActionController::TestCase
  ModelWithKeyAndVersion = Struct.new(:cache_key, :cache_version)

  def setup
    super
    @store = ActiveSupport::Cache::MemoryStore.new
    @controller = FragmentCachingTestController.new
    @controller.perform_caching = true
    @controller.cache_store = @store
    @params = { controller: "posts", action: "index" }
    @controller.params = @params
    @controller.request = @request
    @controller.response = @response

    @m1v1 = ModelWithKeyAndVersion.new("model/1", "1")
    @m1v2 = ModelWithKeyAndVersion.new("model/1", "2")
    @m2v1 = ModelWithKeyAndVersion.new("model/2", "1")
    @m2v2 = ModelWithKeyAndVersion.new("model/2", "2")
  end

  def test_combined_fragment_cache_key
    assert_equal [ :views, "what a key" ], @controller.combined_fragment_cache_key("what a key")
    assert_equal [ :views, "test.host/fragment_caching_test/some_action" ],
      @controller.combined_fragment_cache_key(controller: "fragment_caching_test", action: "some_action")
  end

  def test_read_fragment_with_caching_enabled
    @store.write("views/name", "value")
    assert_equal "value", @controller.read_fragment("name")
  end

  def test_read_fragment_with_caching_disabled
    @controller.perform_caching = false
    @store.write("views/name", "value")
    assert_nil @controller.read_fragment("name")
  end

  def test_read_fragment_with_versioned_model
    @controller.write_fragment([ "stuff", @m1v1 ], "hello")
    assert_equal "hello", @controller.read_fragment([ "stuff", @m1v1 ])
    assert_nil @controller.read_fragment([ "stuff", @m1v2 ])
  end

  def test_fragment_exist_with_caching_enabled
    @store.write("views/name", "value")
    assert @controller.fragment_exist?("name")
    assert_not @controller.fragment_exist?("other_name")
  end

  def test_fragment_exist_with_caching_disabled
    @controller.perform_caching = false
    @store.write("views/name", "value")
    assert_not @controller.fragment_exist?("name")
    assert_not @controller.fragment_exist?("other_name")
  end

  def test_write_fragment_with_caching_enabled
    assert_nil @store.read("views/name")
    assert_equal "value", @controller.write_fragment("name", "value")
    assert_equal "value", @store.read("views/name")
  end

  def test_write_fragment_with_caching_disabled
    assert_nil @store.read("views/name")
    @controller.perform_caching = false
    assert_equal "value", @controller.write_fragment("name", "value")
    assert_nil @store.read("views/name")
  end

  def test_expire_fragment_with_simple_key
    @store.write("views/name", "value")
    @controller.expire_fragment "name"
    assert_nil @store.read("views/name")
  end

  def test_expire_fragment_with_regexp
    @store.write("views/name", "value")
    @store.write("views/another_name", "another_value")
    @store.write("views/primalgrasp", "will not expire ;-)")

    @controller.expire_fragment(/name/)

    assert_nil @store.read("views/name")
    assert_nil @store.read("views/another_name")
    assert_equal "will not expire ;-)", @store.read("views/primalgrasp")
  end

  def test_fragment_for
    @store.write("views/expensive", "fragment content")
    fragment_computed = false

    view_context = @controller.view_context

    buffer = "generated till now -> ".html_safe
    buffer << view_context.send(:fragment_for, "expensive") { fragment_computed = true }

    assert_not fragment_computed
    assert_equal "generated till now -> fragment content", buffer
  end

  def test_html_safety
    assert_nil @store.read("views/name")
    content = "value".html_safe
    assert_equal content, @controller.write_fragment("name", content)

    cached = @store.read("views/name")
    assert_equal content, cached
    assert_equal String, cached.class

    html_safe = @controller.read_fragment("name")
    assert_equal content, html_safe
    assert_predicate html_safe, :html_safe?
  end
end

class FunctionalCachingController < CachingController
  def fragment_cached
  end

  def html_fragment_cached_with_partial
    respond_to do |format|
      format.html
    end
  end

  def xml_fragment_cached_with_html_partial
  end

  def formatted_fragment_cached
    respond_to do |format|
      format.html
      format.xml
    end
  end

  def formatted_fragment_cached_with_variant
    request.variant = :phone if params[:v] == "phone"

    respond_to do |format|
      format.html.phone
      format.html
    end
  end

  def fragment_cached_without_digest
  end

  def fragment_cached_with_options
  end
end

class FunctionalFragmentCachingTest < ActionController::TestCase
  def setup
    super
    @store = ActiveSupport::Cache::MemoryStore.new
    @controller = FunctionalCachingController.new
    @controller.perform_caching = true
    @controller.cache_store = @store
    @controller.enable_fragment_cache_logging = true
  end

  def test_fragment_caching
    get :fragment_cached
    assert_response :success
    expected_body = <<-CACHED
Hello
This bit's fragment cached
Ciao
    CACHED
    assert_equal expected_body, @response.body

    assert_equal "This bit's fragment cached",
      @store.read("views/functional_caching/fragment_cached:#{template_digest("functional_caching/fragment_cached", "html")}/fragment")
  end

  def test_fragment_caching_in_partials
    get :html_fragment_cached_with_partial
    assert_response :success
    assert_match(/Old fragment caching in a partial/, @response.body)

    assert_match("Old fragment caching in a partial",
      @store.read("views/functional_caching/_partial:#{template_digest("functional_caching/_partial", "html")}/test.host/functional_caching/html_fragment_cached_with_partial"))
  end

  def test_skipping_fragment_cache_digesting
    get :fragment_cached_without_digest, format: "html"
    assert_response :success
    expected_body = "<body>\n<p>ERB</p>\n</body>\n"

    assert_equal expected_body, @response.body
    assert_equal "<p>ERB</p>", @store.read("views/nodigest")
  end

  def test_fragment_caching_with_options
    time = Time.now
    get :fragment_cached_with_options
    assert_response :success
    expected_body = "<body>\n<p>ERB</p>\n</body>\n"

    assert_equal expected_body, @response.body
    Time.stub(:now, time + 11) do
      assert_nil @store.read("views/with_options")
    end
  end

  def test_render_inline_before_fragment_caching
    get :inline_fragment_cached
    assert_response :success
    assert_match(/Some inline content/, @response.body)
    assert_match(/Some cached content/, @response.body)
    assert_match("Some cached content",
      @store.read("views/functional_caching/inline_fragment_cached:#{template_digest("functional_caching/inline_fragment_cached", "html")}/test.host/functional_caching/inline_fragment_cached"))
  end

  def test_fragment_cache_instrumentation
    assert_notification("read_fragment.action_controller", controller: "functional_caching", action: "inline_fragment_cached") do
      get :inline_fragment_cached
    end
  end

  def test_html_formatted_fragment_caching
    format = "html"
    get :formatted_fragment_cached, format: format
    assert_response :success
    expected_body = "<body>\n<p>ERB</p>\n</body>\n"

    assert_equal expected_body, @response.body

    assert_equal "<p>ERB</p>",
      @store.read("views/functional_caching/formatted_fragment_cached:#{template_digest("functional_caching/formatted_fragment_cached", format)}/fragment")
  end

  def test_xml_formatted_fragment_caching
    format = "xml"
    get :formatted_fragment_cached, format: format
    assert_response :success
    expected_body = "<body>\n  <p>Builder</p>\n</body>\n"

    assert_equal expected_body, @response.body

    assert_equal "  <p>Builder</p>\n",
      @store.read("views/functional_caching/formatted_fragment_cached:#{template_digest("functional_caching/formatted_fragment_cached", format)}/fragment")
  end

  def test_fragment_caching_with_variant
    format = "html"
    get :formatted_fragment_cached_with_variant, format: format, params: { v: :phone }
    assert_response :success
    expected_body = "<body>\n<p>PHONE</p>\n</body>\n"

    assert_equal expected_body, @response.body

    assert_equal "<p>PHONE</p>",
      @store.read("views/functional_caching/formatted_fragment_cached_with_variant:#{template_digest("functional_caching/formatted_fragment_cached_with_variant", format)}/fragment")
  end

  def test_fragment_caching_with_html_partials_in_xml
    get :xml_fragment_cached_with_html_partial, format: "*/*"
    assert_response :success
  end

  private
    def template_digest(name, format)
      ActionView::Digestor.digest(name: name, format: format, finder: @controller.lookup_context)
    end
end

class CacheHelperOutputBufferTest < ActionController::TestCase
  class MockController
    def read_fragment(name, options)
      false
    end

    def write_fragment(name, fragment, options)
      fragment
    end
  end

  def setup
    super
  end

  def test_output_buffer
    output_buffer = ActionView::OutputBuffer.new
    controller = MockController.new
    cache_helper = Class.new do
      def self.controller; end
      def self.output_buffer; end
      def self.output_buffer=; end
    end
    cache_helper.extend(ActionView::Helpers::CacheHelper)

    cache_helper.stub :controller, controller do
      cache_helper.stub :output_buffer, output_buffer do
        assert_nothing_raised do
          cache_helper.send :fragment_for, "Test fragment name", "Test fragment", &Proc.new { nil }
        end
      end
    end
  end
end

class ViewCacheDependencyTest < ActionController::TestCase
  include ActiveSupport::Testing::RactorsAssertions

  class NoDependenciesController < ActionController::Base
  end

  class HasDependenciesController < ActionController::Base
    view_cache_dependency { "trombone" }
    view_cache_dependency { "flute" }
  end

  def test_view_cache_dependencies_are_empty_by_default
    assert_empty NoDependenciesController.new.view_cache_dependencies
  end

  def test_view_cache_dependencies_are_listed_in_declaration_order
    assert_equal %w(trombone flute), HasDependenciesController.new.view_cache_dependencies
  end

  def test_view_cache_dependencies_are_ractor_safe
    ActiveSupport::Ractors.with(unshareable_proc_action: :raise) do
      controller = Class.new(ActionController::Base) do
        view_cache_dependency { "foo" }
      end

      assert_ractor_shareable controller._view_cache_dependencies
    end
  end
end

class CollectionCacheController < ActionController::Base
  attr_accessor :partial_rendered_times

  def index
    @customers = [Customer.new("david", params[:id] || 1)]
  end

  def index_ordered
    @customers = [Customer.new("david", 1), Customer.new("david", 2), Customer.new("david", 3)]
    render "index"
  end

  def index_explicit_render_in_controller
    @customers = [Customer.new("david", 1)]
    render partial: "customers/customer", collection: @customers, cached: true
  end

  def index_with_comment
    @customers = [Customer.new("david", 1)]
    render partial: "customers/commented_customer", collection: @customers, as: :customer, cached: true
  end

  def index_with_callable_cache_key
    @customers = [Customer.new("david", 1)]
    render partial: "customers/customer", collection: @customers, cached: -> customer { "cached_david" }
  end
end

class CollectionCacheTest < ActionController::TestCase
  def setup
    super
    @controller = CollectionCacheController.new
    @controller.perform_caching = true
    @controller.partial_rendered_times = 0
    @controller.cache_store = ActiveSupport::Cache::MemoryStore.new
    ActionView::PartialRenderer.collection_cache = ActiveSupport::Cache::MemoryStore.new
  end

  def test_collection_fetches_cached_views
    get :index
    assert_equal 1, @controller.partial_rendered_times
    assert_match "david, 1", ActionView::PartialRenderer.collection_cache.read("views/customers/_customer:7c228ab609f0baf0b1f2367469210937/david/1")

    get :index
    assert_equal 1, @controller.partial_rendered_times
  end

  def test_preserves_order_when_reading_from_cache_plus_rendering
    get :index, params: { id: 2 }
    assert_equal 1, @controller.partial_rendered_times
    assert_select ":root", "david, 2"

    get :index_ordered
    assert_equal 3, @controller.partial_rendered_times
    assert_select ":root", /david, 1\s+david, 2\s+david, 3/
  end

  def test_explicit_render_call_with_options
    get :index_explicit_render_in_controller

    assert_select ":root", "david, 1"
  end

  def test_caching_works_with_beginning_comment
    get :index_with_comment
    assert_equal 1, @controller.partial_rendered_times

    get :index_with_comment
    assert_equal 1, @controller.partial_rendered_times
  end

  def test_caching_with_callable_cache_key
    get :index_with_callable_cache_key
    assert_match "david, 1", ActionView::PartialRenderer.collection_cache.read("views/customers/_customer:7c228ab609f0baf0b1f2367469210937/cached_david")
  end
end

class FragmentCacheKeyTestController < CachingController
  attr_accessor :account_id

  fragment_cache_key "v1"
  fragment_cache_key { account_id }
end

class FragmentCacheKeyTest < ActionController::TestCase
  def setup
    super
    @store = ActiveSupport::Cache::MemoryStore.new
    @controller = FragmentCacheKeyTestController.new
    @controller.perform_caching = true
    @controller.cache_store = @store
  end

  def test_combined_fragment_cache_key
    @controller.account_id = "123"
    assert_equal [ :views, "v1", "123", "what a key" ], @controller.combined_fragment_cache_key("what a key")

    @controller.account_id = nil
    assert_equal [ :views, "v1", "what a key" ], @controller.combined_fragment_cache_key("what a key")
  end

  def test_combined_fragment_cache_key_with_envs
    ENV["RAILS_APP_VERSION"] = "55"
    assert_equal [ :views, "55", "v1", "what a key" ], @controller.combined_fragment_cache_key("what a key")

    ENV["RAILS_CACHE_ID"] = "66"
    assert_equal [ :views, "66", "v1", "what a key" ], @controller.combined_fragment_cache_key("what a key")
  ensure
    ENV["RAILS_CACHE_ID"] = ENV["RAILS_APP_VERSION"] = nil
  end
end

class FragmentInputCoverageTest < ActionDispatch::IntegrationTest
  include CookieSessionAppTestHelpers

  class FragmentsController < ActionController::Base
    self.perform_caching = true

    def sign_in
      session[:user_id] = 1
      cookies[:theme] = "dark"
      cookies.signed[:account_id] = 1
      head :ok
    end

    def session_keyed_on_post
      render inline: "<% cache 'post' do %><%= session[:user_id] %><% end %>"
    end

    def session_keyed_on_value
      render inline: "<% cache ['post', session[:user_id]] do %><%= session[:user_id] %><% end %>"
    end

    def whole_session
      render inline: "<% cache ['post', session[:user_id]] do %><%= session.to_hash.size %><% end %>"
    end

    def cookie_keyed_on_post
      render inline: "<% cache 'post' do %><%= cookies[:theme] %><% end %>"
    end

    def signed_cookie_keyed_on_value
      render inline: "<% cache ['post', cookies.signed[:account_id]] do %><%= cookies.signed[:account_id] %><% end %>"
    end

    def authenticity_token
      render inline: "<% cache 'form' do %><%= form_authenticity_token.present? %><% end %>"
    end

    def params_keyed_on_posts
      render inline: "<% cache 'posts' do %><%= params[:page] %><% end %>"
    end

    def params_keyed_on_value
      render inline: "<% cache ['posts', params[:page]] do %><%= params[:page] %><% end %>"
    end

    def nested_params_keyed_on_value
      render inline: "<% cache ['posts', params[:filter][:status]] do %><%= params[:filter][:status] %><% end %>"
    end

    def nested
      render inline: "<% cache 'outer' do %><% cache ['inner', session[:user_id]] do %><%= session[:user_id] %><% end %><% end %>"
    end
  end

  setup do
    @log = StringIO.new
    FragmentsController.cache_store = @store = ActiveSupport::Cache::MemoryStore.new
  end

  test "reports session values, cookies, params and the authenticity token the key does not include" do
    with_check(:log) do
      get "/sign_in"

      {
        "/session_keyed_on_post" => 'The fragment cached in inline template with the key "post" read `session["user_id"]` (Integer), which the key does not include.',
        "/whole_session" => "read the whole session, which the key does not include.",
        "/cookie_keyed_on_post" => 'read `cookies["theme"]` (String)',
        "/params_keyed_on_posts?page=2" => 'read `params["page"]` (String)',
        "/authenticity_token" => 'with the key "form" read the CSRF token, which the key does not include.'
      }.each do |path, message|
        @store.clear
        get path
        assert_match message, @log.string
      end
    end
  end

  test "passes session values, signed cookies and params the key includes" do
    with_check(:raise) do
      get "/sign_in"

      {
        "/session_keyed_on_value" => "1",
        "/signed_cookie_keyed_on_value" => "1",
        "/params_keyed_on_value?page=2" => "2",
        "/nested_params_keyed_on_value?filter[status]=draft" => "draft"
      }.each do |path, body|
        get path
        assert_equal body, response.body
      end
    end
  end

  test "reports the reads of an inner fragment for the outer fragment" do
    with_check(:log) do
      get "/sign_in"
      get "/nested"

      assert_equal "1", response.body
      assert_equal 1, @log.string.scan("The fragment cached").size
      assert_match 'with the key "outer" read `session["user_id"]` (Integer)', @log.string
    end
  end

  test "raises and writes nothing when the key does not cover a read" do
    with_check(:raise) do
      get "/sign_in"

      writes = capture_notifications("cache_write.active_support") do
        error = assert_raises(ActionView::Template::Error) { get "/session_keyed_on_post" }
        assert_instance_of ActionView::UncoveredFragmentInputError, error.cause
        assert_match 'read `session["user_id"]` (Integer)', error.message
        assert_equal "inline template", error.template.short_identifier
      end

      assert_empty writes
    end
  end

  private
    def with_check(action, &block)
      ActionView::FragmentInputCoverage.with(action: action) do
        ActionView::Base.with(logger: ActiveSupport::Logger.new(@log)) do
          with_cookie_session_app(FragmentsController, &block)
        end
      end
    end
end

class CacheHelperInputCoverageTest < ActiveSupport::TestCase
  class Current < ActiveSupport::CurrentAttributes
    attribute :user
  end

  class SessionCurrent < ActiveSupport::CurrentAttributes
    attribute :session
    delegate :user, to: :session, allow_nil: true
  end

  Session = Struct.new(:user)

  Post = Struct.new(:id) do
    def cache_key
      "posts/#{id}"
    end
  end

  # Like a relation, it converts to an array by loading, and compares by loading.
  class Records
    def cache_key
      "records"
    end

    def to_ary
      raise "loaded"
    end

    def ==(other)
      raise "loaded"
    end
  end

  class FragmentsController < ActionController::Base
    self.view_paths = ActionView::FixtureResolver.new(
      "fragments/_current_user.html.erb" => "<% cache key do %><%= CacheHelperInputCoverageTest::Current.user %><% end %>",
      "fragments/_current_user_set_inside.html.erb" => "<% cache key do %><% CacheHelperInputCoverageTest::Current.set(user: 'author') do %><%= CacheHelperInputCoverageTest::Current.user %><% end %><% end %>",
      "fragments/_delegated_user.html.erb" => "<% cache key do %><%= CacheHelperInputCoverageTest::SessionCurrent.user %><% end %>",
      "fragments/_delegated_user_read_before.html.erb" => "<% user = CacheHelperInputCoverageTest::SessionCurrent.user %><% cache [key, user] do %><%= user %><% end %>",
      "fragments/_nested.html.erb" => "<% cache outer_key do %><% cache inner_key do %><%= CacheHelperInputCoverageTest::Current.user %><% end %><% end %>",
      "fragments/_translated.html.erb" => "<% cache key do %><%= t('.title', default: 'Title') %><% end %>",
      "fragments/_localized.html.erb" => "<% cache key do %><%= l(date) %><% end %>",
      "fragments/_translated_in_locale.html.erb" => "<% cache key do %><%= t('.title', default: 'Title', locale: :en) %><% end %>",
      "fragments/_translated_in_nil_locale.html.erb" => "<% cache key do %><%= t('.title', default: 'Title', locale: nil) %><% end %>"
    )
  end

  setup do
    @store = ActiveSupport::Cache::MemoryStore.new
    @log = StringIO.new
    @post = Post.new(1)

    @controller = FragmentsController.new
    @controller.perform_caching = true
    @controller.cache_store = @store
  end

  teardown do
    Current.reset
  end

  test "reports a Current attribute that the fragment read and its key does not include" do
    Current.user = "david"

    assert_equal "david", render_fragment("current_user", check: :log, key: [@post])

    assert_match "The fragment cached in fragments/_current_user.html.erb with the key \"posts/1\" " \
      "read `CacheHelperInputCoverageTest::Current.user` (String), which the key does not include.", @log.string
    assert_no_match "david", @log.string
  end

  test "compares a value read to the parts of the key without converting either" do
    Current.user = ["david"]

    render_fragment("current_user", check: :log, key: [@post, Records.new])

    assert_match "read `CacheHelperInputCoverageTest::Current.user` (Array)", @log.string
  end

  test "passes a Current attribute that the key includes" do
    Current.user = "david"

    assert_equal "david", render_fragment("current_user", check: :raise, key: [@post, Current.user])
  end

  test "reports the attribute a delegated Current method reads, and passes the value read before the fragment" do
    SessionCurrent.session = Session.new("david")

    assert_equal "david", render_fragment("delegated_user", check: :log, key: [@post, SessionCurrent.user])
    assert_match "read `CacheHelperInputCoverageTest::SessionCurrent.session` (CacheHelperInputCoverageTest::Session)", @log.string

    @log.truncate(0)
    assert_equal "david", render_fragment("delegated_user_read_before", check: :log, key: @post)
    assert_empty @log.string
  ensure
    SessionCurrent.reset
  end

  test "reports a Current attribute that is not set" do
    Current.user = "david"
    Current.user = nil

    render_fragment("current_user", check: :log, key: [@post])

    assert_match "read `CacheHelperInputCoverageTest::Current.user` (NilClass)", @log.string
  end

  test "reports a Current attribute of a class first used in the fragment" do
    ActiveSupport::CurrentAttributes.clear_all

    render_fragment("current_user", check: :log, key: [@post])

    assert_match "read `CacheHelperInputCoverageTest::Current.user` (NilClass)", @log.string
  end

  test "reports a Current attribute provided by a set block opened outside the fragment" do
    Current.set(user: "david") { render_fragment("current_user", check: :log, key: [@post]) }

    assert_match "read `CacheHelperInputCoverageTest::Current.user` (String)", @log.string
  end

  test "passes a Current attribute provided by a set block opened in the fragment" do
    Current.user = "david"

    assert_equal "author", render_fragment("current_user_set_inside", check: :raise, key: [@post])
    assert_equal "david", Current.user
  end

  test "reports the locale a translation or localization without a locale read when the key does not include it" do
    I18n.stub(:available_locales, [:en, :de]) do
      { "translated" => {}, "translated_in_nil_locale" => {}, "localized" => { date: Date.new(2026, 9, 30) } }.each do |partial, locals|
        @log.truncate(0)
        render_fragment(partial, check: :log, key: [@post], **locals)

        assert_match "fragments/_#{partial}.html.erb with the key \"posts/1\" read `I18n.locale` (Symbol)", @log.string
      end
    end
  end

  test "passes the locale when the key includes it, the translation is given it, or the application has a single locale" do
    I18n.stub(:available_locales, [:en, :de]) do
      assert_equal "Title", render_fragment("translated", check: :raise, key: [@post, I18n.locale])
      assert_equal "Title", render_fragment("translated_in_locale", check: :raise, key: [@post])
    end

    I18n.stub(:available_locales, [:en]) do
      assert_equal "Title", render_fragment("translated", check: :raise, key: [@post])
    end
  end

  test "reports the reads of an inner fragment for both fragments" do
    Current.user = "david"

    render_fragment("nested", check: :log, outer_key: [@post, :outer], inner_key: [@post, :inner])

    assert_match "with the key \"posts/1/outer\" read `CacheHelperInputCoverageTest::Current.user`", @log.string
    assert_match "with the key \"posts/1/inner\" read `CacheHelperInputCoverageTest::Current.user`", @log.string
  end

  test "reads nothing on a cache hit" do
    Current.user = "david"
    render_fragment("current_user", check: :log, key: [@post])
    @log.truncate(0)

    Current.user = "jeremy"

    assert_equal "david", render_fragment("current_user", check: :log, key: [@post])
    assert_empty @log.string
  end

  test "checks nothing when disabled" do
    Current.user = "david"

    I18n.stub(:available_locales, [:en, :de]) do
      assert_equal "david", render_fragment("current_user", check: false, key: [@post])
      assert_equal "Title", render_fragment("translated", check: false, key: [@post])
    end

    assert_empty @log.string
  end

  test "subscribes to request input reads only while enabled" do
    ActionView::FragmentInputCoverage.with(action: :log) do
      assert ActiveSupport::Notifications.notifier.listening?("read_input.action_dispatch")
    end

    assert_not ActiveSupport::Notifications.notifier.listening?("read_input.action_dispatch")
  end

  test "rejects an unknown action" do
    error = assert_raises(ArgumentError) { ActionView::FragmentInputCoverage.action = :warn }
    assert_equal "config.action_view.action_on_uncovered_fragment_input must be false, :log or :raise, got :warn", error.message
  end

  private
    def render_fragment(partial, check:, **locals)
      view = @controller.view_context
      view.logger = ActiveSupport::Logger.new(@log)

      ActionView::FragmentInputCoverage.with(action: check) do
        view.render(partial: "fragments/#{partial}", locals: locals).strip
      end
    end
end

class FragmentInputCoverageLiveTest < ActionController::TestCase
  class Current < ActiveSupport::CurrentAttributes
    attribute :user
  end

  # The Live action and the test each render a fragment, one open while the other reads.
  class LiveFragmentsController < ActionController::Base
    include ActionController::Live

    cattr_accessor :live_opened, :test_opened, :live_read
    helper_method :live_fragment_opened, :live_fragment_read, :test_fragment_opened

    def index
      response.stream.write "streaming\n"
      response.stream.write view_context.render(inline: "<% cache ['live', params[:page]] do %>" \
        "<% live_fragment_opened %><%= params[:page] %><% live_fragment_read %><% end %>")
    ensure
      response.stream.close
    end

    private
      def live_fragment_opened
        live_opened << true
        test_opened.pop(timeout: 5)
      end

      def live_fragment_read
        live_read << true
      end

      def test_fragment_opened
        test_opened << true
        live_read.pop(timeout: 5)
      end
  end

  tests LiveFragmentsController

  setup do
    def @controller.new_controller_thread(&block)
      original_new_controller_thread(&block)
    end

    @log = StringIO.new
    LiveFragmentsController.perform_caching = true
    LiveFragmentsController.cache_store = ActiveSupport::Cache::MemoryStore.new
    LiveFragmentsController.live_opened, LiveFragmentsController.test_opened, LiveFragmentsController.live_read = Queue.new, Queue.new, Queue.new
  end

  test "a fragment check does not share its frames between the request thread and a Live action's thread" do
    ActionView::FragmentInputCoverage.with(action: :log) do
      ActionView::Base.with(logger: ActiveSupport::Logger.new(@log)) do
        render_test_fragment("<% cache 'before' do %><% end %>")

        get :index, params: { page: "2" }
        LiveFragmentsController.live_opened.pop(timeout: 5)

        # The test fragment creates the Current instance it reads, while the Live fragment is open.
        ActiveSupport::ExecutionContext.clear
        render_test_fragment("<% cache ['test', 'x', nil] do %><%= ActionController::Parameters.new(t: 'x')[:t] %>" \
          "<%= FragmentInputCoverageLiveTest::Current.user %><% test_fragment_opened %><% end %>")

        assert_equal "streaming\n2", response.body
      end
    end

    assert_no_match "The fragment cached", @log.string
  end

  private
    def render_test_fragment(template)
      controller = LiveFragmentsController.new
      controller.view_context.render(inline: template)
    end
end
