# Archived scripts, 2026-06-13

These scripts are kept for traceability but are no longer the current workflow.

Current replacements:

```text
kexec_dropbear_until_new.sh  -> scripts/kexec_adb_until_new.sh
test_dropbear_initrd.sh      -> scripts/kexec_adb_until_new.sh
push_initrd.sh               -> scripts/install_kexec_payload.sh
build_kxsh.sh                -> scripts/install_system_dropbear.sh
wifi_probe*.sh               -> scripts/wifi_bringup.sh
wifi_power.sh                -> scripts/wifi_bringup.sh
verify_kexec_shutdown.sh     -> one-off shutdown diagnostic
```

The active Wi-Fi path is `scripts/build_patched_mbox_initrd.sh` plus
`scripts/enable_wifi_bringup_once.sh`.
