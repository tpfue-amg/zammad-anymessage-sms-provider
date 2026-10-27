# Copyright (C) 2026 AnyMessage GmbH, https://www.anymessage.cloud/en

require 'rails_helper'

RSpec.describe Channel::Driver::Sms::AnyMessage do
  let(:api_url) { described_class::DEFAULT_API_URL }
  let(:channel) { create(:channel, area: 'Sms::Account', group_id: Group.first.id, options: options) }
  let(:options) do
    {
      adapter:       'sms/any_message',
      webhook_token: '0123456789abcdef0123456789abcdef',
      username:      'zammad',
      password:      'secret',
      sender:        '+491710000000',
    }
  end

  it 'is listed as SMS adapter' do
    expect(described_class.definition).to include(adapter: 'sms/any_message')
  end

  describe '#deliver' do
    it 'sends the SMS and returns true' do
      stub = stub_request(:post, api_url)
        .with(
          basic_auth: %w[zammad secret],
          body:       { sender: '+491710000000', recipient: '491710000001', content: 'Hello', dlr: false }.to_json,
        )
        .to_return(status: 200, body: { messageId: 'sms-1234' }.to_json, headers: { 'Content-Type' => 'application/json' })

      expect(channel.deliver(recipient: '+49 171 0000001', message: 'Hello')).to be(true)
      expect(stub).to have_been_requested
    end

    it 'collects the messageId' do
      stub_request(:post, api_url).to_return(status: 200, body: { messageId: 'sms-1234' }.to_json)

      ids = []
      Channel::Driver::Sms::AnyMessage::MessageIdCollector.collect do
        channel.deliver(recipient: '+491710000001', message: 'Hello')
        ids = Channel::Driver::Sms::AnyMessage::MessageIdCollector.ids
      end

      expect(ids).to eq(['sms-1234'])
    end

    it 'raises a readable error on permanent errors' do
      stub_request(:post, api_url).to_return(status: 400, body: { error: 'recipient not numeric' }.to_json)

      expect { channel.deliver(recipient: 'abc', message: 'Hello') }
        .to raise_error(RuntimeError, %r{permanent error \(HTTP 400\): recipient not numeric})
    end

    it 'raises a temporary error on rate limiting' do
      stub_request(:post, api_url).to_return(status: 429, body: { error: 'rate limited' }.to_json)

      expect { channel.deliver(recipient: '+491710000001', message: 'Hello') }
        .to raise_error(RuntimeError, %r{temporary error \(HTTP 429\)})
    end

    it 'unwraps inspect strings of connection errors' do
      stub_request(:post, api_url).to_timeout

      expect { channel.deliver(recipient: '+491710000001', message: 'Hello') }
        .to raise_error(RuntimeError) { |e| expect(e.message).not_to include('#<', '<', '>') }
    end

    it 'does not send in import mode' do
      Setting.set('import_mode', true)

      expect(channel.deliver(recipient: '+491710000001', message: 'Hello')).to be(true)
      expect(a_request(:post, api_url)).not_to have_been_made
    end
  end

  describe '#process' do
    let(:payload) { JSON.parse(Rails.root.join('spec/fixtures/files/any_message/inbound.json').read) }

    it 'creates a ticket with customer and article' do
      expect { channel.process(payload) }
        .to change(Ticket, :count).by(1)
        .and change(Ticket::Article, :count).by(1)

      article = Ticket::Article.last
      expect(article).to have_attributes(
        body:       "Help, my order is late\n\nSent 2026-10-13 13:45 UTC",
        from:       '+491710000001',
        to:         nil,
        message_id: 'sms-mo-01a13582-b400-7d56-95f2-3a99858a0ae1',
      )
      expect(article.preferences[:sms][:ReceivedAt]).to eq('2026-10-13T13:45:20Z')
      expect(article.ticket.customer.mobile).to eq('+491710000001')
      expect(article.ticket.preferences[:channel_id]).to eq(channel.id)
    end

    it 'adds a follow-up to an open SMS ticket' do
      channel.process(payload)

      expect { channel.process(payload.merge('messageId' => 'mo-5678')) }
        .to not_change(Ticket, :count)
        .and change(Ticket::Article, :count).by(1)
    end

    it 'maps the recipient number once AMG sends it' do
      channel.process(payload.deep_merge('recipient' => { 'msisdn' => '491710000000' }))

      expect(Ticket::Article.last.to).to eq('+491710000000')
    end

    it 'ignores duplicates' do
      channel.process(payload)

      expect { channel.process(payload) }.not_to change(Ticket::Article, :count)
    end

    it 'rejects payloads without sender' do
      expect { channel.process(payload.except('sender')) }.to raise_error(Exceptions::UnprocessableContent)
    end
  end
end
