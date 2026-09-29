# admin_user role

Creates the `upayan` sudo user + SSH key. Deliberately does **not** touch `PermitRootLogin` — that
cutover is a separate, explicitly confirmed step:

1. Run this role.
2. From a **fresh terminal/session** (not the one used to apply the role), confirm:
   `ssh upayan@100.96.250.81` works and `sudo -l` succeeds.
3. Only then, in a separate confirmed change: set `PermitRootLogin no` in `sshd_config` and
   restart `sshd`.
4. Owner sets a strong root password via the Hetzner web console (not over SSH, never committed)
   as the break-glass path — `PasswordAuthentication no` stays enforced for SSH regardless, so this
   password only ever works through the console.

Skipping straight to step 3 without verifying step 2 risks locking out SSH access entirely.
