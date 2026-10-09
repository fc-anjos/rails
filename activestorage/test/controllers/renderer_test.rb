# frozen_string_literal: true

require "test_helper"
require "database/setup"

class ActiveStorage::RendererTest < ActiveSupport::TestCase
  setup do
    @blob = create_file_blob filename: "racecar.jpg"
    @renderer = ApplicationController.renderer.new(http_host: "broadcast.example:8443", https: true)
    @requester_url_options = { protocol: "https://", host: "requester.example", port: 3000 }
  end

  test "blob URLs render outside a request from the renderer's request" do
    ActiveStorage::Current.set(url_options: nil) do
      url = @renderer.render(inline: "<%= blob.url %>", locals: { blob: @blob })

      assert_match %r"\Ahttps://broadcast\.example:8443/", url
      assert_nil ActiveStorage::Current.url_options
    end
  end

  test "blob URLs keep the current url options with :caller" do
    with_renderer_url_options(:caller) do
      ActiveStorage::Current.set(url_options: @requester_url_options) do
        url = @renderer.render(inline: "<%= blob.url %>", locals: { blob: @blob })

        assert_match %r"\Ahttps://requester\.example:3000/", url
      end
    end
  end

  test "blob URLs use the renderer's request over the current url options with :renderer" do
    with_renderer_url_options(:renderer) do
      ActiveStorage::Current.set(url_options: @requester_url_options) do
        url = @renderer.render(inline: "<%= blob.url %>", locals: { blob: @blob })

        assert_match %r"\Ahttps://broadcast\.example:8443/", url
        assert_equal "requester.example", ActiveStorage::Current.url_options[:host]
      end
    end
  end

  test "an unknown renderer_url_options value raises" do
    assert_no_changes -> { ActiveStorage.renderer_url_options } do
      error = assert_raises(ArgumentError) { ActiveStorage.renderer_url_options = true }

      assert_match "Unknown renderer URL options source true", error.message
    end
  end

  private
    def with_renderer_url_options(source)
      previous, ActiveStorage.renderer_url_options = ActiveStorage.renderer_url_options, source
      yield
    ensure
      ActiveStorage.renderer_url_options = previous
    end
end
