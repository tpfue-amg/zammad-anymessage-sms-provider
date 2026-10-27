# Deployment

This guide covers the two supported ways to run Zammad:

- [A. Server install](#a-server-install-debrpm-package) (deb/rpm package, Zammad in `/opt/zammad`, systemd)
- [B. Docker](#b-docker--docker-compose) (`zammad-docker-compose` or a similar setup, image `ghcr.io/zammad/zammad`)

Both scenarios share the [prerequisites](#prerequisites), the [channel configuration](#channel-configuration-both-scenarios) and the [verification checklist](#verification-checklist-both-scenarios).

> This is an early release. Deploy it to a **staging** instance first.

---

## Prerequisites

- **Zammad version.** Use one of the versions listed under [Tested Zammad versions](README.md#tested-zammad-versions) in the README. The delivery report hook depends on the internals of Zammad's `CommunicateSmsJob`.
- **Public HTTPS URL.** AnyMessage must be able to reach Zammad from the internet for inbound SMS and delivery reports. Check that the FQDN in Admin > System > Base is correct.
- **AnyMessage account.** You need:
  - API username and password (Basic auth)
  - a two-way virtual number, which is the sender customers can reply to
- **Backup.** Take a Zammad backup before installing.

---

## A. Server install (deb/rpm package)

In this scenario the provider is installed as a **Zammad package** (`.zpm`). Zammad copies the files into `/opt/zammad` and records them in its package registry. The package then appears under Admin > System > Packages, and you can uninstall it cleanly later.

### A.1 Build the package

You can build on any machine with Ruby installed. The system Ruby is enough.

```sh
ruby bin/build-package
# -> dist/AnyMessageSms-0.1.3.zpm
```

### A.2 Install

1. Copy the package to the server:
   ```sh
   scp dist/AnyMessageSms-0.1.3.zpm root@zammad.example.com:/tmp/
   ```
2. Install it. Use **one** of these two options.
   - **Option 1, web UI:** go to Admin > System > Packages and upload `AnyMessageSms-0.1.3.zpm`.
   - **Option 2, CLI (run on the server):**
     ```sh
     chmod 644 /tmp/AnyMessageSms-0.1.3.zpm
     zammad run rails r "Package.install(file: '/tmp/AnyMessageSms-0.1.3.zpm')"
     ```
3. Restart Zammad. This is **required**: the route, the initializer and the `CommunicateSmsJob` hook only load at boot. The command restarts the web, worker and websocket services.
   ```sh
   systemctl restart zammad
   ```

You don't need `bundle install`, `rake zammad:package:migrate` or `rake assets:precompile`. The package adds no gems, no database migrations and no frontend assets.

### A.3 Check the installation

```sh
# package registered?
zammad run rails r "p Package.pluck(:name, :version)"

# files in place?
ls -l /opt/zammad/app/models/channel/driver/sms/any_message.rb \
      /opt/zammad/app/models/channel/driver/sms/any_message/

# driver loadable?
zammad run rails r "p Channel::Driver::Sms::AnyMessage.definition[:name]"

# DLR route registered?
zammad run rails r "puts Rails.application.routes.routes.map { |r| r.path.spec.to_s }.grep(/sms_any_message/)"
```

### A.4 Optional: restrict the webhooks at the reverse proxy

The inbound webhook and the DLR endpoint are protected only by the secret token in the URL. An IP allowlist adds a second layer. Ask AnyMessage support for the IP addresses AMG sends callbacks from. Add the allowlist in the nginx vhost for Zammad (`/etc/nginx/sites-enabled/zammad.conf`):

```nginx
location ~ ^/api/v1/(sms_webhook/|sms_any_message/dlr/) {
    allow <anymessage-ip>;  # one line per AnyMessage callback IP
    deny  all;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_pass http://zammad-railsserver;
}
```

`sms_webhook` is shared with all other SMS providers. Only restrict it if AnyMessage is your only SMS provider.

### A.5 Update to a new provider version

```sh
scp dist/AnyMessageSms-0.1.4.zpm root@zammad.example.com:/tmp/
zammad run rails r "Package.install(file: '/tmp/AnyMessageSms-0.1.4.zpm')"
systemctl restart zammad
```

### A.6 After a Zammad upgrade

Check whether the package files survived the upgrade:

```sh
ls /opt/zammad/app/models/channel/driver/sms/any_message.rb
```

If the files are missing:

```sh
zammad run rails r "Package.reinstall_all"
systemctl restart zammad
```

Then run the [verification checklist](#verification-checklist-both-scenarios) again.

### A.7 Rollback / uninstall

1. Deactivate the AnyMessage channel under Admin > Channels > SMS.
2. Uninstall the package:
   ```sh
   zammad run rails r "Package.uninstall(name: 'AnyMessageSms', version: '0.1.3')"
   ```
3. Restart Zammad:
   ```sh
   systemctl restart zammad
   ```

Deactivate the channel **before** uninstalling. If you don't, Zammad keeps an SMS channel whose adapter no longer exists.

---

## B. Docker / docker compose

Packages installed into a running container are **lost when the container is recreated**. That happens on every `docker compose up` after an image update. So in Docker the provider is built **into the image**, or mounted from the host. Don't use the Admin > Packages upload in Docker.

The provider files are needed in every container that runs Rails code:

| Service | Why |
|---|---|
| `zammad-railsserver` | webhooks, DLR endpoint, admin channel form, Test button |
| `zammad-scheduler` | runs `CommunicateSmsJob` (sending, messageId tracking) |
| `zammad-websocket` | loads the same Rails app, so it should see the same code |
| `zammad-init` | boots the Rails app for migrations. Harmless, but keep it consistent. |

`zammad-docker-compose` runs all of these from one image (`${IMAGE_REPO}:${VERSION}`), so a custom image covers every service at once.

### B.1 Recommended: custom image

This repo includes `docker/Dockerfile`. It extends the official image and copies the provider files into `/opt/zammad`, owned by the image user `1000:1000`.

1. Build the image, using the **same Zammad version** as your current deployment:
   ```sh
   docker build -f docker/Dockerfile \
     --build-arg ZAMMAD_VERSION=7.2.0-0011 \
     -t zammad-anymessage:7.2.0-0011 .
   ```
2. Point docker compose at the custom image. In the `.env` of your `zammad-docker-compose` checkout, set:
   ```sh
   IMAGE_REPO=zammad-anymessage
   VERSION=7.2.0-0011
   ```
   If several hosts or Kubernetes nodes need the image, push it to your registry instead and use that as `IMAGE_REPO`:
   ```sh
   docker tag zammad-anymessage:7.2.0-0011 registry.example.com/zammad-anymessage:7.2.0-0011
   docker push registry.example.com/zammad-anymessage:7.2.0-0011
   ```
3. Recreate the containers:
   ```sh
   docker compose up -d
   ```
4. Check the installation:
   ```sh
   docker compose exec zammad-railsserver ls app/models/channel/driver/sms/any_message.rb
   docker compose exec zammad-railsserver bundle exec rails r "p Channel::Driver::Sms::AnyMessage.definition[:name]"
   ```

The provider won't appear under Admin > System > Packages, because the Zammad package registry isn't used here. That's expected.

**Zammad upgrades:** rebuild the custom image with the new `ZAMMAD_VERSION`, update `VERSION` in `.env`, then run `docker compose up -d`. Make this a fixed step in your upgrade routine, otherwise an upgrade quietly drops the provider.

**Kubernetes (Helm chart `zammad/zammad`):** set `image.repository` and `image.tag` in your values to the custom image.

### B.2 Alternative: bind-mount the files (no custom image)

Use this for quick tests, or when you can't build images. Copy `docker/docker-compose.override.yml.example` into your `zammad-docker-compose` directory as `docker-compose.override.yml`. Then adjust `ANYMESSAGE_SRC` to point at this repo's location on the host:

```sh
cp docker/docker-compose.override.yml.example /path/to/zammad-docker-compose/docker-compose.override.yml
cd /path/to/zammad-docker-compose
ANYMESSAGE_SRC=/opt/any-zammad-sms-provider docker compose up -d
```

Docker compose picks up `docker-compose.override.yml` automatically. The files are mounted read-only into all Rails services.

`ANYMESSAGE_SRC` set on the command line only applies to that one `up`. A later `docker compose up -d` without it falls back to the default path in the override file. So set the variable in the `.env` of your `zammad-docker-compose` checkout, or change the default path in `docker-compose.override.yml` to your checkout location.

This survives image upgrades, because the mounts are reapplied on every `up`. The downside is that the host checkout becomes part of your deployment. Don't change it without restarting.

To update the provider, or to check which version is running:

```sh
git -C "$ANYMESSAGE_SRC" pull
git -C "$ANYMESSAGE_SRC" log -1 --oneline          # deployed commit
docker compose restart zammad-railsserver zammad-scheduler zammad-websocket
docker compose exec zammad-railsserver bundle exec rails r "p Channel::Driver::Sms::AnyMessage.definition[:name]"
```

### B.3 Optional: restrict the webhooks

The `zammad-nginx` container uses the bundled nginx config. Usually an external reverse proxy (Traefik, nginx, HAProxy) sits in front of it. Add the IP allowlist from [A.4](#a4-optional-restrict-the-webhooks-at-the-reverse-proxy) there, with the same paths and the same caveat about `sms_webhook`.

### B.4 Rollback / uninstall

1. Deactivate the AnyMessage channel under Admin > Channels > SMS.
2. Remove the provider:
   - **Custom image:** set `IMAGE_REPO` and `VERSION` in `.env` back to the official image (`ghcr.io/zammad/zammad`).
   - **Bind mounts:** remove `docker-compose.override.yml`.
3. Recreate the containers:
   ```sh
   docker compose up -d
   ```

---

## Channel configuration (both scenarios)

1. Go to Admin > Channels > SMS.
   - For **SMS Account** (inbound and replies) or **SMS Notification** (triggers), choose **AnyMessage**.
   - Fill in **Username** and **Password**.
   - Set **Sender**. Use the two-way virtual number for SMS Account. An alphanumeric sender is fine for notifications.
   - Set **Destination Group**. This is for SMS Account only.
   - Optionally, turn on **Request delivery reports**.
2. Send a test SMS with the **Test** button.
3. Copy the read-only **Webhook Token** from the channel form. Ask AnyMessage support (support@anymessage.cloud) to configure these URLs:
   - Inbound SMS: `https://<zammad-fqdn>/api/v1/sms_webhook/<webhook_token>`
   - Delivery reports: `https://<zammad-fqdn>/api/v1/sms_any_message/dlr/<webhook_token>`

## Verification checklist (both scenarios)

- [ ] AnyMessage is listed as a provider under Admin > Channels > SMS.
- [ ] The Test button delivers an SMS to a real phone. If it fails, the form shows a readable error.
- [ ] An agent reply on an SMS ticket arrives, and the article shows the delivery status "success".
- [ ] An SMS to the virtual number creates a ticket in the destination group. The article has no recipient number until AnyMessage adds it to the MO push.
- [ ] A reply from the same phone is added to the same ticket.
- [ ] A delivery report updates the article. Check the access log for `GET /api/v1/sms_any_message/dlr/<webhook_token>?message_id=...` with status 200.
- [ ] The logs contain no credentials and no errors:
  - server: `/opt/zammad/log/production.log`
  - Docker: `docker compose logs zammad-railsserver zammad-scheduler`
  ```sh
  grep -i anymessage /opt/zammad/log/production.log | tail
  ```
