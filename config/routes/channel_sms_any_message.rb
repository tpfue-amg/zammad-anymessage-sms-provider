# Copyright (C) 2026 AnyMessage GmbH, https://www.anymessage.cloud/en

Zammad::Application.routes.draw do
  api_path = Rails.configuration.api_path

  # AMG pushes DLRs as GET with query parameters.
  match api_path + '/sms_any_message/dlr/:token', to: 'channels_sms_any_message#dlr', via: %i[get post]
end
