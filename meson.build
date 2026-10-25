project(
  'io.github.techmore.NmapUI',
  'vala', 'c',
  version: '0.1.0',
  meson_version: '>= 0.59.0',
  default_options: ['warning_level=1'],
)

gnome = import('gnome')
i18n = import('i18n')
app_id = meson.project_name()
prefix = get_option('prefix')
bindir = prefix / get_option('bindir')
datadir = prefix / get_option('datadir')

conf = configuration_data()
conf.set_quoted('GETTEXT_PACKAGE', app_id)
conf.set_quoted('VERSION', meson.project_version())
configure_file(output: 'config.h', configuration: conf)
add_project_arguments('-include', 'config.h', language: 'c')
add_project_arguments(
  ['--vapidir', meson.current_source_dir() / 'vapi'],
  '--target-glib=2.74',
  language: 'vala',
)

config_vapi = meson.get_compiler('vala').find_library('config', dirs: meson.current_source_dir() / 'vapi')

app_deps = [
  dependency('glib-2.0', version: '>= 2.74'),
  dependency('gio-2.0'),
  dependency('gtk4', version: '>= 4.10'),
  dependency('granite-7', version: '>= 7.7.0'),
  dependency('webkitgtk-6.0'),
  dependency('libsoup-3.0'),
  dependency('json-glib-1.0'),
  config_vapi,
]

executable(
  app_id,
  'src/Application.vala',
  'src/Backend.vala',
  'src/RuntimeSchema.vala',
  'src/PagePresentation.vala',
  'src/MainWindow.vala',
  'src/NavigationPolicy.vala',
  dependencies: app_deps,
  install: true,
)

navigation_test = executable(
  'test-navigation-policy',
  'src/NavigationPolicy.vala', 'tests/test_navigation_policy.vala',
  dependencies: [dependency('glib-2.0', version: '>= 2.74'), dependency('gio-2.0')],
)
test('navigation-policy', navigation_test)

runtime_test = executable(
  'test-runtime-schema',
  'src/RuntimeSchema.vala', 'tests/test_runtime_schema.vala',
  dependencies: [dependency('glib-2.0'), dependency('json-glib-1.0')],
)
test('runtime-schema', runtime_test)

# One-shot JSON summary of the local scanner, shared by the Wingpanel indicator.
install_data('helper/nmapui-summary', install_dir: bindir, install_mode: 'rwxr-xr-x')

subdir('data')
if get_option('indicator')
  subdir('indicator')
endif

gnome.post_install(
  gtk_update_icon_cache: true,
  update_desktop_database: true,
)

page_test = executable(
  'test-page-presentation',
  'src/PagePresentation.vala', 'tests/test_page_presentation.vala',
  dependencies: [dependency('glib-2.0'), dependency('gobject-2.0')],
)
test('page-presentation', page_test)
