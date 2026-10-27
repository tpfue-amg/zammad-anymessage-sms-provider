# Copyright (C) 2026 AnyMessage GmbH, https://www.anymessage.cloud/en

class Channel::Driver::Sms::AnyMessage < Channel::Driver::Sms::Base
  NAME = 'sms/any_message'.freeze
  DEFAULT_API_URL = 'https://api.anymessage.cloud/sms/v1/initiate'.freeze

  # HTTP status codes of the AMG API which are worth retrying (CommunicateSmsJob retries on raise).
  TEMPORARY_ERROR_CODES = %w[0 429 500 502 504].freeze

  def fetchable?(_channel)
    false
  end

  def deliver(options, attr, _notification = false)
    Rails.logger.info "Sending SMS to recipient #{attr[:recipient]}"

    return true if Setting.get('import_mode')

    Rails.logger.info "Backend sending AnyMessage SMS to #{attr[:recipient]}"
    begin
      message_id = send_create(options, attr)
      Channel::Driver::Sms::AnyMessage::MessageIdCollector.add(message_id)
      true
    rescue => e
      Rails.logger.debug { "AnyMessage error: #{e.inspect}" }
      raise e
    end
  end

  def send_create(options, attr)
    return if Setting.get('developer_mode')

    response = UserAgent.post(
      options[:api_url].presence || DEFAULT_API_URL,
      {
        sender:    options[:sender].to_s.gsub(%r{\s}, ''),
        recipient: normalize_number(attr[:recipient]),
        content:   attr[:message],
        dlr:       ActiveModel::Type::Boolean.new.cast(options[:dlr]) || false,
      },
      {
        json:          true,
        user:          options[:username],
        password:      options[:password],
        open_timeout:  4,
        read_timeout:  15,
        total_timeout: 20,
        log:           { facility: 'AnyMessage', log_only_on_error: true },
      },
    )

    raise error_message(response) if !response.success?

    Rails.logger.warn "AnyMessage warning: #{response.data['warning']}" if response.data&.dig('warning').present?

    response.data&.dig('messageId')
  end

  def process(_options, attr, channel)
    inbound = Channel::Driver::Sms::AnyMessage::InboundMessage.new(attr)
    Rails.logger.info "Receiving SMS from recipient #{inbound.from}"

    # prevent already created articles
    return ok_response if inbound.message_id.present? && Ticket::Article.exists?(message_id: inbound.message_id)

    user = user_by_mobile(inbound.from)
    UserInfo.current_user_id = user.id

    process_ticket(inbound, channel, user)

    ok_response
  end

  def create_ticket(inbound, channel, user)
    title = cut_title(inbound.text)
    ticket = Ticket.new(
      group_id:    channel.group_id,
      title:       title,
      state_id:    Ticket::State.find_by(default_create: true).id,
      priority_id: Ticket::Priority.find_by(default_create: true).id,
      customer_id: user.id,
      preferences: {
        channel_id: channel.id,
        sms:        {
          From: inbound.from,
          To:   inbound.to,
        }
      }
    )
    ticket.save!
    ticket
  end

  def create_article(inbound, channel, ticket)
    Ticket::Article.create!(
      ticket_id:    ticket.id,
      type:         article_type_sms,
      sender:       Ticket::Article::Sender.find_by(name: 'Customer'),
      body:         inbound.text,
      from:         inbound.from,
      to:           inbound.to,
      message_id:   inbound.message_id,
      content_type: 'text/plain',
      preferences:  {
        channel_id: channel.id,
        sms:        {
          From:       inbound.from,
          To:         inbound.to,
          ReceivedAt: inbound.received_at,
        },
      }
    )
  end

  def self.definition
    {
      name:         'AnyMessage',
      adapter:      'sms/any_message',
      account:      [
        { name: 'options::webhook_token', display: __('Webhook Token'), tag: 'input', type: 'text', limit: 200, null: false, default: Digest::MD5.hexdigest(SecureRandom.uuid), disabled: true, readonly: true },
        { name: 'options::api_url', display: __('API URL'), tag: 'input', type: 'text', limit: 255, null: true, placeholder: DEFAULT_API_URL },
        { name: 'options::username', display: __('Username'), tag: 'input', type: 'text', limit: 200, null: false },
        { name: 'options::password', display: __('Password'), tag: 'input', type: 'password', limit: 200, null: false },
        { name: 'options::sender', display: __('Sender'), tag: 'input', type: 'text', limit: 21, null: false, placeholder: '+491710000000' },
        { name: 'options::dlr', display: __('Request delivery reports'), tag: 'boolean', null: true, default: false, options: { true => 'yes', false => 'no' } },
        { name: 'group_id', display: __('Destination Group'), tag: 'tree_select', null: false, relation: 'Group', nulloption: true, filter: { active: true } },
      ],
      notification: [
        { name: 'options::webhook_token', display: __('Webhook Token'), tag: 'input', type: 'text', limit: 200, null: false, default: Digest::MD5.hexdigest(SecureRandom.uuid), disabled: true, readonly: true },
        { name: 'options::api_url', display: __('API URL'), tag: 'input', type: 'text', limit: 255, null: true, placeholder: DEFAULT_API_URL },
        { name: 'options::username', display: __('Username'), tag: 'input', type: 'text', limit: 200, null: false },
        { name: 'options::password', display: __('Password'), tag: 'input', type: 'password', limit: 200, null: false },
        { name: 'options::sender', display: __('Sender'), tag: 'input', type: 'text', limit: 21, null: false, placeholder: 'MyCompany' },
        { name: 'options::dlr', display: __('Request delivery reports'), tag: 'boolean', null: true, default: false, options: { true => 'yes', false => 'no' } },
      ],
    }
  end

  private

  def ok_response
    ['application/json; charset=UTF-8;', { status: 'ok' }.to_json]
  end

  # AMG v1 expects digits only in international format, without leading '+' or '00'.
  def normalize_number(number)
    number.to_s.gsub(%r{[^\d+]}, '').sub(%r{\A(\+|00)}, '')
  end

  def error_message(response)
    detail = begin
      JSON.parse(response.body.to_s)['error']
    rescue JSON::ParserError, TypeError
      nil
    end

    kind = TEMPORARY_ERROR_CODES.include?(response.code.to_s) ? 'temporary' : 'permanent'
    "AnyMessage API #{kind} error (HTTP #{response.code}): #{plain_text(detail.presence || response.error).presence || 'no error details'}"
  end

  # UserAgent errors are often Ruby inspect strings ("#<Net::OpenTimeout: ...>"), which the
  # admin UI shows HTML-escaped. Unwrap them and drop remaining angle brackets.
  def plain_text(text)
    text.to_s.gsub(%r{#<([^>]*)>}, '\1').delete('<>').squish
  end
end
