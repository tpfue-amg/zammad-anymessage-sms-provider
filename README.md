# AnyMessage SMS provider for Zammad

This is a Zammad package that adds **AnyMessage** (AnyMessage Gateway, AMG) as an SMS provider. Find it under Admin > Channels > SMS.

It covers:

- outbound SMS (agent replies and trigger notifications)
- inbound SMS (new tickets and follow-ups)
- delivery reports (DLR)

The driver ships as a Zammad package, so Zammad core is never patched.

## Status

**Early release (0.1.x). Deploy to a staging instance first.**

| Area | Status |
|---|---|
| Outbound SMS | Implemented against AMG `POST /sms/v1/initiate` (Basic auth). |
| Inbound SMS (MO) | Implemented. The mapping follows a real AMG MO push. AMG doesn't send the recipient number yet. |
| Delivery reports | Implemented. The mapping follows a real AMG DLR callback. |
| Specs | Written against real (anonymized) AMG samples. They need a Zammad dev environment to run. |

### Tested Zammad versions

| Zammad version | Install type | Result |
|---|---|---|
| `7.2.0-9789badf.docker` | Docker, bind mounts ([DEPLOYMENT.md](DEPLOYMENT.md#b2-alternative-bind-mount-the-files-no-custom-image)) | Deploys and the DLR route answers. Full end-to-end test pending. |

The delivery report hook depends on the internals of Zammad's `CommunicateSmsJob`. Re-check after every Zammad upgrade.

## Project layout

```
AnyMessageSms.szpm                                  package manifest (name, version, file list)
bin/build-package                                   builds dist/AnyMessageSms-<version>.zpm
app/models/channel/driver/sms/any_message.rb        SMS driver (deliver, process, admin form definition)
app/models/channel/driver/sms/any_message/          inbound/DLR payload mapping, messageId tracking
app/controllers/channels_sms_any_message_controller.rb   delivery report endpoint
config/routes/channel_sms_any_message.rb            DLR route
config/initializers/any_message_sms.rb              hooks into CommunicateSmsJob
docker/                                             Dockerfile and compose override for Docker deployments
spec/                                               RSpec tests (run inside a Zammad checkout)
```

## Packaging

The provider ships as a **Zammad package (`.zpm`)**. That's a JSON file with the source files embedded as base64. When you install it, Zammad writes those files into its install directory (for example `/opt/zammad`) and records them, so it can upgrade or remove them cleanly later.

### Build

Ruby is required. The system Ruby is enough, because the build script only uses the standard library.

```sh
ruby bin/build-package          # -> dist/AnyMessageSms-<version>.zpm
```

Before you build a new release, bump `version` and add a `change_log` entry in `AnyMessageSms.szpm`. If you add new source files, list them in `files` too.

## Deployment

**[DEPLOYMENT.md](DEPLOYMENT.md)** has step-by-step instructions for both scenarios. In short:

| | Server install (deb/rpm) | Docker / docker compose |
|---|---|---|
| Delivery | `.zpm` package installed via Admin > Packages or `Package.install` | Custom image from `docker/Dockerfile`, or bind mounts (`docker/docker-compose.override.yml.example`) |
| Activate | `systemctl restart zammad` | `docker compose up -d` |
| Zammad upgrade | Check the files are still there, `Package.reinstall_all` if needed | Rebuild the image with the new `ZAMMAD_VERSION` |
| Uninstall | `Package.uninstall(...)` + restart | Switch back to the official image, or remove the override |

## Configuration

1. In Zammad, go to Admin > Channels > SMS and choose **AnyMessage** as the provider. Then fill in:
   - **Username** and **Password**: your AMG API credentials (Basic auth).
   - **Sender**: your two-way virtual number. Customers can only reply to that number. An alphanumeric sender is fine for notifications only.
   - **Request delivery reports**: turn on if you want delivery status shown on articles.
   - **Destination Group**: inbound SMS accounts only.
2. Ask AnyMessage support (support@anymessage.cloud) to configure the push URLs. `<webhook_token>` is shown read-only in the channel form.
   - Inbound SMS: `https://<zammad-fqdn>/api/v1/sms_webhook/<webhook_token>`
   - Delivery reports: `https://<zammad-fqdn>/api/v1/sms_any_message/dlr/<webhook_token>`
3. Use the **Test** button in the channel form to send a test SMS.

## Inbound SMS endpoint (MO)

AMG pushes inbound SMS to the SMS webhook of Zammad core. All SMS providers share this route; the token selects the channel.

```
POST https://<zammad-fqdn>/api/v1/sms_webhook/<webhook_token>
Content-Type: application/json
```

- **Token**: the read-only **Webhook Token** of the channel. Only active channels of type **SMS Account** are matched. SMS Notification channels never receive inbound SMS.
- **Method and body**: `POST` with a JSON body. The `Content-Type: application/json` header is needed, otherwise Rails does not parse the body. `GET` with query parameters works as well (`sender[msisdn]=...`).
- **Authentication**: only the token in the URL. There is no signature check yet. See [DEPLOYMENT.md](DEPLOYMENT.md#a4-optional-restrict-the-webhooks-at-the-reverse-proxy) for an optional IP allowlist.

Payload (real AMG sample, anonymized):

```json
{
  "type": "mo",
  "messageId": "sms-mo-01a13582-b400-7d56-95f2-3a99858a0ae1",
  "sender": { "msisdn": "491710000001" },
  "recipient": { "integrationUuid": "example-integration-uuid" },
  "content": { "text": "Help, my order is late" },
  "messageTimestamp": "2026-10-13T13:45:20Z"
}
```

| Field | Required | Used for |
|---|---|---|
| `sender.msisdn` | yes | Customer lookup by mobile number, article `from`. Digits only; Zammad stores it as `+<digits>`. |
| `content.text` | yes | Article body and ticket title |
| `messageId` | no | Article `message_id`. A push with a known `messageId` is ignored, so retries don't create duplicates. |
| `messageTimestamp` | no | Stored in the article as `preferences.sms.ReceivedAt` |
| `recipient.msisdn` | no | Article `to`. Not sent by AMG yet; the key name is an assumption. |
| `type`, `recipient.integrationUuid` | no | Ignored |

An SMS from a number with an open SMS ticket is added to that ticket. Otherwise a new ticket is created in the channel's **Destination Group**.

Responses:

| Status | Body | When |
|---|---|---|
| `200` | `{"status":"ok"}` | Article created, or duplicate `messageId` ignored |
| `404` | `{"message":"channel not found"}` | Unknown token, or the channel is inactive or not an SMS Account |
| `422` | error message | `sender.msisdn` or `content.text` missing |

Test it with curl:

```sh
curl -X POST "https://<zammad-fqdn>/api/v1/sms_webhook/<webhook_token>" \
  -H 'Content-Type: application/json' \
  -d '{"type":"mo","messageId":"sms-mo-test-1","sender":{"msisdn":"491710000001"},"recipient":{"integrationUuid":"example-integration-uuid"},"content":{"text":"Test"},"messageTimestamp":"2026-10-13T13:45:20Z"}'
```

## Delivery report endpoint (DLR)

AMG calls the DLR URL as `GET` with query parameters (`POST` is accepted too). This route is added by the package.

```
GET https://<zammad-fqdn>/api/v1/sms_any_message/dlr/<webhook_token>?message_id=sms-6f61...&status_code=2&status=delivered&error_code=0&error=no%20error&done_date=2026-10-09%2008%3A58
```

- **Token**: the **Webhook Token** of an active AnyMessage channel (SMS Account or SMS Notification). The comparison is constant-time.
- **Required**: `message_id` and `status_code` (or `status` as a name). Optional: `error_code`, `error`, `done_date`.
- **Status codes**: final `2` delivered, `3` expired, `4` deleted, `5` undeliverable, `7` unknown, `8` rejected, `9` skipped. Non-final `0` scheduled, `1` enroute, `6` accepted.

How reports are matched: AMG returns a `messageId` for each sent SMS. The package stores these IDs on the outgoing article (the first one in `message_id`, all of them in `preferences.any_message.message_ids`). Each report is stored under `preferences.any_message.delivery_reports`. The article's `delivery_status` becomes `fail` as soon as any recipient fails, and `success` once every recipient is delivered.

Responses:

| Status | Body | When |
|---|---|---|
| `200` | `{"status":"ok"}` | Report applied |
| `200` | `{"status":"unknown message"}` | No article with this `messageId` (answered with 200 to avoid retry storms) |
| `404` | `{"message":"channel not found"}` | Unknown token, or the channel is inactive or not AnyMessage |
| `422` | error message | `message_id` or `status_code` missing |

## Known limitations

- Zammad core cuts outgoing SMS to 160 characters.
- Only Basic auth is supported. Bearer tokens are not supported yet.
- MO and DLR pushes are not signed. Protection relies on the secret token and, optionally, an IP allowlist.
- Inbound SMS articles have no recipient number until AnyMessage adds it to the MO push.
- A delivery report that arrives before the sending job has stored the `messageId` is not applied.

## Roadmap

- Map the recipient number of inbound SMS once AMG sends it.
- Run the specs and an end-to-end test on the current Zammad stable release.
- Signature verification for MO and DLR pushes, if AMG adds signing.
- Optional Bearer token authentication.
- Buffer early delivery reports instead of dropping them.

## Development

### Ruby on Ubuntu 22.04 (or WSL)

- **Syntax checks and package builds:** `sudo apt install ruby` (Ruby 3.0) is enough.
  ```sh
  find app config spec -name '*.rb' -exec ruby -c {} \;
  ```
- **Running Zammad and the specs:** you need the Ruby version from Zammad's `.ruby-version` (3.4.9 on `develop`). Build it with rbenv and ruby-build, then install the services Zammad needs.
  ```sh
  sudo apt install git curl build-essential autoconf bison rustc \
    libssl-dev libyaml-dev libreadline-dev zlib1g-dev libncurses-dev \
    libffi-dev libgdbm-dev libgdbm-compat-dev libdb-dev uuid-dev
  git clone https://github.com/rbenv/rbenv.git ~/.rbenv
  git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
  # add ~/.rbenv/bin to PATH and `eval "$(rbenv init -)"` to ~/.bashrc
  rbenv install 3.4.9

  sudo apt install postgresql libpq-dev redis-server \
    libimlib2 libimlib2-dev shared-mime-info nodejs
  corepack enable                    # pnpm for Zammad assets
  bundle config set without "mysql"
  ```

### Tests

Copy or symlink the `app/`, `config/` and `spec/` files into a Zammad source checkout, then run:

```sh
bundle exec rspec spec/models/channel/driver/sms/any_message_spec.rb \
                  spec/models/channel/driver/sms/any_message/delivery_report_spec.rb \
                  spec/requests/channels_sms_any_message_spec.rb
```

`spec/fixtures/files/any_message/dlr.json` and `inbound.json` are real AMG samples. The phone number and text in `inbound.json` are anonymized.

## License

GNU Affero General Public License v3.0 (AGPL-3.0), the same license as Zammad. See [LICENSE](LICENSE).
