# Copyright (C) 2026 AnyMessage GmbH, https://www.anymessage.cloud/en

require 'rails_helper'

RSpec.describe Channel::Driver::Sms::AnyMessage::DeliveryReport do
  let(:payload) { JSON.parse(Rails.root.join('spec/fixtures/files/any_message/dlr.json').read) }
  let(:article) do
    create(:ticket_article,
           type_name:   'sms',
           message_id:  'sms-6f61a982-5ef3-4aa3-972c-9038e312dfb9',
           preferences: { 'any_message' => { 'message_ids' => ['sms-6f61a982-5ef3-4aa3-972c-9038e312dfb9'] } })
  end

  before { article }

  it 'marks the article as delivered' do
    described_class.new(payload).process!

    expect(article.reload.preferences).to include('delivery_status' => 'success')
    expect(article.preferences.dig('any_message', 'delivery_reports', 'sms-6f61a982-5ef3-4aa3-972c-9038e312dfb9', 'status_name')).to eq('delivered')
  end

  it 'marks the article as failed' do
    described_class.new(payload.merge('status_code' => '5', 'status' => 'undeliverable', 'error_code' => '1', 'error' => 'absent subscriber')).process!

    expect(article.reload.preferences).to include('delivery_status' => 'fail', 'delivery_status_message' => 'AnyMessage: undeliverable (absent subscriber)')
  end

  it 'keeps the delivery status for non-final reports' do
    described_class.new(payload.merge('status_code' => '1', 'status' => 'enroute')).process!

    expect(article.reload.preferences).not_to include('delivery_status')
  end

  it 'waits for all recipients before marking success' do
    article.update!(preferences: { 'any_message' => { 'message_ids' => %w[sms-6f61a982-5ef3-4aa3-972c-9038e312dfb9 sms-5678] } })

    described_class.new(payload).process!
    expect(article.reload.preferences).not_to include('delivery_status')

    described_class.new(payload.merge('message_id' => 'sms-5678')).process!
    expect(article.reload.preferences).to include('delivery_status' => 'success')
  end

  it 'falls back to the status name without status_code' do
    described_class.new(payload.except('status_code')).process!

    expect(article.reload.preferences).to include('delivery_status' => 'success')
  end

  it 'returns nil for unknown messageIds' do
    expect(described_class.new(payload.merge('message_id' => 'sms-unknown')).process!).to be_nil
  end
end
