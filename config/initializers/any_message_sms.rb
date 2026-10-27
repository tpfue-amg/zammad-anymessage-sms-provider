# Copyright (C) 2026 AnyMessage GmbH, https://www.anymessage.cloud/en

Rails.application.config.to_prepare do
  CommunicateSmsJob.prepend(Channel::Driver::Sms::AnyMessage::CommunicateSmsJobExtension)
  ChannelsSmsController.prepend(Channel::Driver::Sms::AnyMessage::ChannelsSmsControllerExtension)
end
