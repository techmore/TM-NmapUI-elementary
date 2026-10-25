desktop_conf = configuration_data()
desktop_conf.set('APP_ID', app_id)
# Desktop Exec uses percent field codes even inside a quoted executable path.
desktop_conf.set('BINDIR', bindir.replace('%', '%%'))

configure_file(
  input: app_id + '.desktop.in',
  output: app_id + '.desktop',
  configuration: desktop_conf,
  install: true,
  install_dir: datadir / 'applications',
)

configure_file(
  input: app_id + '.metainfo.xml.in',
  output: app_id + '.metainfo.xml',
  configuration: desktop_conf,
  install: true,
  install_dir: datadir / 'metainfo',
)

install_data(
  'icons' / app_id + '.svg',
  install_dir: datadir / 'icons' / 'hicolor' / 'scalable' / 'apps',
)
install_data(
  'icons' / app_id + '-symbolic.svg',
  install_dir: datadir / 'icons' / 'hicolor' / 'symbolic' / 'apps',
)

# systemd user unit template consumed by scripts/install-backend.sh.
install_data('nmapui.service.in', 'engine-revision', install_dir: datadir / app_id)
