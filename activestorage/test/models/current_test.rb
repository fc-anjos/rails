# frozen_string_literal: true

require "test_helper"
require "database/setup"

class ActiveStorage::CurrentTest < ActiveSupport::TestCase
  test "url_options are carried by ActiveSupport::CarriedState, so blob URLs can be generated in isolated state" do
    blob = create_blob(filename: "funky.jpg")
    carried = ActiveSupport::CarriedState.capture

    url = ActiveSupport::CurrentAttributes::Isolation.run do
      ActiveSupport::IsolatedExecutionState.isolated do
        assert_nil ActiveStorage::Current.url_options

        ActiveSupport::CarriedState.restore(carried) do
          assert_equal({ protocol: "https://", host: "example.com", port: nil }, ActiveStorage::Current.url_options)
          blob.url
        end
      end
    end

    assert_match %r{\Ahttps://example.com/}, url
  end

  test "a render through ActionController::Renderer isolated from the caller's state builds blob URLs" do
    blob = create_blob(filename: "funky.jpg")

    url = ActionController::Base.with(renderer_isolates_execution_state: true, action_on_unprovided_renderer_input: :raise) do
      ActionController::Base.render(inline: "<%= blob.url %>", locals: { blob: blob })
    end

    assert_match %r{\Ahttps://example.com/}, url
  end
end
