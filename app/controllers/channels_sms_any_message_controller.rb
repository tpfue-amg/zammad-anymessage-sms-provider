# Copyright (C) 2026 AnyMessage GmbH, https://www.anymessage.cloud/en

# Public endpoint for AnyMessage delivery reports (DLR).
#
# The token in the path must match the webhook token of an active AnyMessage channel.
class ChannelsSmsAnyMessageController < ApplicationController
  skip_before_action :verify_csrf_token

  def dlr
    if !channel_by_token(params['token'])
      render json: { message: 'channel not found' }, status: :not_found
      return
    end

    article = Channel::Driver::Sms::AnyMessage::DeliveryReport.new(params.permit!.to_h).process!

    # Unknown messageIds are answered with 200 to avoid retry storms.
    render json: { status: article ? 'ok' : 'unknown message' }, status: :ok
  end

  private

  def any_message_channels
    Channel.where(active: true, area: %w[Sms::Account Sms::Notification]).select do |channel|
      channel.options[:adapter] == Channel::Driver::Sms::AnyMessage::NAME
    end
  end

  def channel_by_token(token)
    any_message_channels.find do |channel|
      channel.options[:webhook_token].present? &&
        ActiveSupport::SecurityUtils.secure_compare(channel.options[:webhook_token], token)
    end
  end
end
