libwingpanel_dep = dependency('wingpanel-9')
indicators_dir = libwingpanel_dep.get_variable(pkgconfig: 'indicatorsdir')

indicator_deps = [
  libwingpanel_dep,
  dependency('granite-7', version: '>= 7.7.0'),
  dependency('json-glib-1.0'),
]

shared_module(
  'nmapui',
  'Indicator.vala',
  dependencies: indicator_deps,
  install: true,
  install_dir: indicators_dir,
)

install_data(
  'icons/mseries-nmapui-radar-symbolic.svg',
  'icons/mseries-nmapui-radar-idle-symbolic.svg',
  'icons/mseries-nmapui-radar-attention-symbolic.svg',
  install_dir: datadir / 'icons' / 'hicolor' / 'symbolic' / 'apps',
)

# Headless render probe (not installed): see probe/run-probe.sh.
executable(
  'render-probe',
  'Indicator.vala', 'probe/render-probe.vala',
  dependencies: indicator_deps,
  install: false,
)
