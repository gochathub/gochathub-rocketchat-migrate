# gochathub-rocketchat-migration

Planning notes and backup tooling for moving an existing Rocket.Chat server to
[goChatHub](https://github.com/gochathub). Only relevant if you are migrating off
Rocket.Chat; new goChatHub installs never need this repo.

The importer itself is the `rcmigrate` command in
[gochathub-server](https://github.com/gochathub/gochathub-server) (see its
README, `docs/CLI.md` and ADR-019). It reads a `mongodump --archive` of the
`rocketchat` database and needs no MongoDB at import time. Re-runs are
idempotent, so a fresh dump can be imported right before cutover.

## Contents

- `BACKUP-README.md`, `backup-mongodb.sh` — weekly `mongodump` of a Dockerized
  Rocket.Chat, following Rocket.Chat's
  [Docker Compose deployment docs](https://docs.rocket.chat/v1/docs/deploy-with-docker-docker-compose).
  Paths assume `/opt/stacks/rocketchat`; adjust to your host.
- `compose.yml` — the Rocket.Chat + MongoDB stack the backups were taken from.
- `REQUIREMENTS.md`, `DESIGN.md` — requirements and design written before the
  importer was built. Historical: the importer shipped as `rcmigrate` (not
  `chatserver migrate rocketchat`), so trust the server docs where they differ.

## Backups contain user data

`*.archive` files hold every user, message and password hash from the source
server. They are gitignored here; keep them off shared storage and delete them
once the cutover is verified.

## Contributing and security

See the [contributing guide](https://github.com/gochathub/.github/blob/main/CONTRIBUTING.md) and [code of conduct](https://github.com/gochathub/.github/blob/main/CODE_OF_CONDUCT.md). Report vulnerabilities privately through the Security tab, not in issues: [security policy](https://github.com/gochathub/.github/blob/main/SECURITY.md).

## License

[MIT](LICENSE) © Brian Tafoya

## Acknowledgements and trademarks

goChatHub is an independent project, not affiliated with, endorsed by, or
sponsored by Rocket.Chat Technologies Corp. This repo only reads data from
[Rocket.Chat](https://github.com/RocketChat/Rocket.Chat) (MIT, outside its
`ee/` directories) and contains no Rocket.Chat source code. Rocket.Chat is a
trademark of Rocket.Chat Technologies Corp.; MongoDB is a trademark of MongoDB,
Inc. Names are used only to identify compatibility.
