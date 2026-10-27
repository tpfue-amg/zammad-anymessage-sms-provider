# Copyright (C) 2026 AnyMessage GmbH, https://www.anymessage.cloud/en

require 'rails_helper'

RSpec.describe 'AnyMessage SMS webhooks', type: :request do
  let(:token)   { '0123456789abcdef0123456789abcdef' }
  let(:channel) do
    create(:channel, area: 'Sms::Account', group_id: Group.first.id, options: {
             adapter:       'sms/any_message',
             webhook_token: token,
             username:      'zammad',
             password:      'secret',
             sender:        '+491710000000',
           })
  end

  before { channel }

  describe 'inbound SMS via core webhook' do
    let(:payload) { JSON.parse(Rails.root.join('spec/fixtures/files/any_message/inbound.json').read) }

    it 'creates an article' do
      expect { post "/api/v1/sms_webhook/#{token}", params: payload, as: :json }
        .to change(Ticket::Article, :count).by(1)

      expect(response).to have_http_status(:ok)
    end

    it 'returns 404 for unknown tokens' do
      post '/api/v1/sms_webhook/unknown', params: payload, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'test SMS from the admin UI' do
    let(:admin) { create(:admin) }

    before { authenticated_as(admin) }

    it 'returns the plain error message without inspect wrapper' do
      stub_request(:post, Channel::Driver::Sms::AnyMessage::DEFAULT_API_URL)
        .to_return(status: 400, body: { error: 'Alphanumeric sender exceeds maximum length of 11 characters' }.to_json)

      post '/api/v1/channels_sms/test', params: {
        options:   { adapter: 'sms/any_message', username: 'zammad', password: 'secret', sender: 'MyCompanyName' },
        recipient: '+491710000001',
        message:   'Test',
      }, as: :json

      expect(json_response).to include(
        'error'       => 'AnyMessage API permanent error (HTTP 400): Alphanumeric sender exceeds maximum length of 11 characters',
        'error_human' => 'AnyMessage API permanent error (HTTP 400): Alphanumeric sender exceeds maximum length of 11 characters',
      )
    end

    it 'returns success' do
      stub_request(:post, Channel::Driver::Sms::AnyMessage::DEFAULT_API_URL)
        .to_return(status: 200, body: { messageId: 'sms-1234' }.to_json)

      post '/api/v1/channels_sms/test', params: {
        options:   { adapter: 'sms/any_message', username: 'zammad', password: 'secret', sender: 'MyCompany' },
        recipient: '+491710000001',
        message:   'Test',
      }, as: :json

      expect(json_response).to include('success' => true)
    end
  end

  describe 'delivery reports' do
    let(:payload) { JSON.parse(Rails.root.join('spec/fixtures/files/any_message/dlr.json').read) }
    let(:article) { create(:ticket_article, type_name: 'sms', message_id: 'sms-6f61a982-5ef3-4aa3-972c-9038e312dfb9') }

    it 'accepts the AMG callback' do
      article
      get "/api/v1/sms_any_message/dlr/#{token}", params: payload

      expect(response).to have_http_status(:ok)
      expect(article.reload.preferences).to include('delivery_status' => 'success')
    end

    it 'accepts POST requests' do
      article
      post "/api/v1/sms_any_message/dlr/#{token}", params: payload, as: :json

      expect(article.reload.preferences).to include('delivery_status' => 'success')
    end

    it 'keeps the delivery status for enroute reports' do
      article
      get "/api/v1/sms_any_message/dlr/#{token}", params: payload.merge('status_code' => '1', 'status' => 'enroute')

      expect(json_response).to include('status' => 'ok')
      expect(article.reload.preferences).not_to include('delivery_status')
    end

    it 'returns 404 if the channel is inactive' do
      channel.update!(active: false)
      get "/api/v1/sms_any_message/dlr/#{token}", params: payload

      expect(response).to have_http_status(:not_found)
    end

    it 'answers unknown messageIds with 200' do
      get "/api/v1/sms_any_message/dlr/#{token}", params: payload

      expect(json_response).to include('status' => 'unknown message')
    end

    it 'returns 404 for unknown tokens' do
      get '/api/v1/sms_any_message/dlr/unknown', params: payload

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 422 without message_id' do
      get "/api/v1/sms_any_message/dlr/#{token}", params: payload.except('message_id')

      expect(response).to have_http_status(422)
    end
  end
end
