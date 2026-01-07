MS Manager Full Installer (with dynamic menus + updater)

Install / update:
  sudo bash install-ms-manager.sh

Update commands (after install):
  sudo ms-manager -update                 # update ms-manager only (uses /etc/ms-server/update.conf)
  sudo ms-manager -update --zip           # download + extract full package zip (and run installer if present)
  sudo ms-manager -update --zip-menu      # update menus only from a zip

Set update URLs:
  sudo nano /etc/ms-server/update.conf
