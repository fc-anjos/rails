# frozen_string_literal: true

require "test_helper"
require "database/setup"

class ActiveStorage::CurrentTest < ActiveSupport::TestCase
  test "url_options are carried into isolated contexts, so blob URLs can be generated there" do
    blob = create_blob(filename: "funky.jpg")

    url = ActiveSupport::CurrentAttributes::Isolation.run(carry: true) do
      assert_equal({ protocol: "https://", host: "example.com", port: nil }, ActiveStorage::Current.url_options)
      blob.url
    end

    assert_match %r{\Ahttps://example.com/}, url
  end

  test "url_options are not carried into contexts isolated without carry, as for a job" do
    ActiveSupport::CurrentAttributes::Isolation.run do
      assert_nil ActiveStorage::Current.url_options
    end
  end

  test "a render through ActionController::Renderer isolated from the caller's attributes builds blob URLs" do
    blob = create_blob(filename: "funky.jpg")

    url = ActionController::Base.with(renderer_isolates_current_attributes: true, action_on_unprovided_renderer_input: :raise) do
      ActionController::Base.render(inline: "<%= blob.url %>", locals: { blob: blob })
    end

    assert_match %r{\Ahttps://example.com/}, url
  end
end
