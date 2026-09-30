# frozen_string_literal: true

require "abstract_unit"
require "action_dispatch/middleware/session/abstract_store"

module ActionDispatch
  module Session
    class AbstractStoreTest < ActiveSupport::TestCase
      class MemoryStore < AbstractStore
        def initialize(app)
          @sessions = {}
          super
        end

        def find_session(env, sid)
          sid ||= 1
          session = @sessions[sid] ||= {}
          [sid, session]
        end

        def write_session(env, sid, session, options)
          @sessions[sid] = session
        end

        def session_exists?(req)
          true
        end
      end

      def test_session_is_set
        env = {}
        as = MemoryStore.new app
        as.call(env)

        assert @env
        assert ActionDispatch::Http::Session.find ActionDispatch::Request.new @env
      end

      def test_new_session_object_is_merged_with_old
        env = {}
        as = MemoryStore.new app
        as.call(env)

        assert @env
        session = ActionDispatch::Http::Session.find ActionDispatch::Request.new @env
        session["foo"] = "bar"

        as.call(@env)
        session1 = ActionDispatch::Http::Session.find ActionDispatch::Request.new @env

        assert_not_equal session, session1
        assert_equal session.to_hash, session1.to_hash
      end

      def test_update_raises_an_exception_if_arg_not_hashable
        env = {}
        as = MemoryStore.new app
        as.call(env)
        session = ActionDispatch::Http::Session.find ActionDispatch::Request.new env

        assert_raise TypeError do
          session.update("Not hashable")
        end
      end

      def test_keyed_reads_publish_read_input_events_with_the_key
        session = loaded_session("foo" => { "bar" => 1 })

        reads = capture_reads do
          session[:foo]
          session.dig(:foo, "bar")
          session.has_key?(:foo)
          session.key?(:foo)
          session.include?(:foo)
          session.fetch(:foo)
          session.id
          session.id_was
        end

        assert_equal [[:session, "foo"]] * 6 + [[:session, "session_id"]] * 2, reads
      end

      def test_whole_session_reads_publish_read_input_events_without_a_key
        session = loaded_session("foo" => "bar")

        reads = capture_reads do
          session.keys
          session.values
          session.to_hash
          session.to_h
          session.empty?
          session.each { }
        end

        assert_equal [[:session, nil]] * 6, reads
      end

      def test_read_input_event_payload_carries_the_request
        session = loaded_session("foo" => "bar")

        events = capture_notifications("read_input.action_dispatch") { session[:foo] }

        assert_equal 1, events.size
        assert_kind_of ActionDispatch::Request, events.first.payload[:request]
        assert_same @env, events.first.payload[:request].env
      end

      def test_loading_writing_and_committing_the_session_publishes_no_read_input_events
        as = MemoryStore.new(lambda { |env| ActionDispatch::Request.new(env).session[:foo] = "bar"; [200, {}, []] })

        assert_empty capture_reads { as.call({}) }
      end

      def test_reads_made_while_the_framework_reads_publish_nothing
        session = loaded_session("foo" => "bar")
        request = ActionDispatch::Request.new(@env)

        reads = capture_reads do
          request.reading_for_framework do
            session[:foo]
            request.reading_for_framework { session.to_hash }
            session.id
          end
        end

        assert_empty reads
      end

      def test_reads_on_another_thread_are_published_while_the_framework_reads
        session = loaded_session("foo" => "bar")
        request = ActionDispatch::Request.new(@env)

        reads = capture_reads do
          request.reading_for_framework do
            Thread.new { session[:foo] }.join
            session[:bar]
          end
        end

        assert_equal [[:session, "foo"]], reads
      end

      def test_reads_are_published_again_after_the_framework_read_raises
        session = loaded_session("foo" => "bar")
        request = ActionDispatch::Request.new(@env)

        reads = capture_reads do
          assert_raises(RuntimeError) { request.reading_for_framework { raise "boom" } }
          session[:foo]
        end

        assert_equal [[:session, "foo"]], reads
      end

      def test_session_and_cookie_reads_do_not_instrument_without_a_subscriber
        session = loaded_session("foo" => "bar")
        cookies = ActionDispatch::Request.new(@env).cookie_jar
        cookies["foo"] = "bar"

        assert_not_called(ActiveSupport::Notifications, :instrument) do
          assert_equal "bar", session[:foo]
          assert_equal "bar", session.fetch(:foo)
          assert_equal({ "foo" => "bar" }, session.to_hash)
          assert_equal 1, session.id
          assert_equal "bar", cookies[:foo]
          assert_equal "bar", cookies.fetch(:foo)
          assert cookies.key?(:foo)
          assert_equal({ "foo" => "bar" }, cookies.to_hash)
        end
      end

      private
        def loaded_session(data)
          MemoryStore.new(app).call({})
          session = ActionDispatch::Http::Session.find(ActionDispatch::Request.new(@env))
          session.update(data)
          session
        end

        def app(&block)
          @env = nil
          lambda { |env| @env = env }
        end
    end
  end
end
