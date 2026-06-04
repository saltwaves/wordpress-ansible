# WordPress Ansible

Reusable Ansible provisioning for a tuned single-server WordPress host. It is
intended for current Ubuntu LTS images and uses Ubuntu packages plus the Sury
PHP repository for pinned PHP branches.

The playbook installs and configures:

* deploy user, sudo, SSH hardening, and UFW
* attached WordPress data volume mounted at `/srv/wordpress`
* nginx WordPress virtual host
* PHP-FPM, defaulting to PHP 8.4
* MySQL, Redis, WP-CLI, Fail2Ban, Git, rsync, and supporting tools

## Usage

Install collection dependencies:

```sh
ansible-galaxy collection install -r collections/requirements.yml
```

Configure inventory:

```ini
[production]
203.0.113.10 ansible_user=root wordpress_data_device=/dev/vdb
```

Set project variables in inventory, group vars, or `--extra-vars`. The most
important variables are:

```yaml
deploy_user: ansible
deploy_user_public_key_path: ~/.ssh/id_rsa.pub
php_version: "8.4"
php_install_sury_repository: true
php_optional_packages:
  - "php{{ php_version }}-imagick"
  - "php{{ php_version }}-redis"
wordpress_domain: example.com
wordpress_domains:
  - example.com
  - www.example.com
wordpress_data_mount: /srv/wordpress
wordpress_web_root: /srv/wordpress/public
mysql_create_wordpress_database: true
wordpress_db_name: wordpress
wordpress_db_user: wordpress
wordpress_db_password: set-this-from-vault-or-ci-secret
mysql_wordpress_user_auth_plugin: caching_sha2_password
```

Run:

```sh
ansible-playbook -i hosts provision.yml
```

Validate locally:

```sh
scripts/validate.sh
```

`php_packages` contains required PHP-FPM and WordPress packages. Packages in
`php_optional_packages` are installed only when the configured apt repositories
publish them for the pinned PHP branch.

## Migration

`scripts/migrate-wordpress.sh` provides generic initial and final migration
passes for WordPress files and database data. The destination server pulls files
from the source via `rsync` using SSH agent forwarding, then imports a compressed
database dump.

Set `DEST_SSH_PRIVATE_KEY_FILE` when the destination host needs a specific SSH
key. Run `scripts/migrate-wordpress.sh --help` for all required and optional
environment variables.
