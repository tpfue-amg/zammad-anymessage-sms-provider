# Copyright (C) 2026 AnyMessage GmbH, https://www.anymessage.cloud/en

# Prepended to ChannelsSmsController (see config/initializers/any_message_sms.rb).
# The core test action returns `error: e.inspect`, which the admin UI prefers over
# `error_human` and shows HTML-escaped ("#&lt;RuntimeError: ...&gt;"). For the AnyMessage
# adapter the plain error message is returned in both fields instead.
module Channel::Driver::Sms::AnyMessage::ChannelsSmsControllerExtension
  def test
    return super if params.dig(:options, :adapter) != Channel::Driver::Sms::AnyMessage::NAME

    resp = Channel::Driver::Sms::AnyMessage.new.deliver(params[:options], params.permit(:recipient, :message).to_h)
    render json: { success: resp }
  rescue => e
    render json: { error: e.message, error_human: e.message }
  end
end
