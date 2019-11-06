project('iopipe', 'd', default_options: ['optimization=3'], version: '0.1.7', license: 'BSL-1.0' )
common_project_arguments = ['-dip25', '-dip1000', '-dip1008', '-release'] #, '--d-debug'
add_project_arguments(common_project_arguments, language: 'd')

# semver
version = meson.project_version().split('.')
major_version = version[0].to_int()
minor_version = version[1].to_int()
micro_version = version[2].to_int()

# base
dc = meson.get_compiler('d')

# Source files

sources = [ 'source/iopipe/buffer.d',
            'source/iopipe/bufpipe.d',
            'source/iopipe/stream.d',
            'source/iopipe/textpipe.d',
            'source/iopipe/traits.d',
            'source/iopipe/valve.d',
            'source/iopipe/zip.d']
inc_dir =  include_directories('source/')

# Compiler and linker flags
common_dflags = []
common_ldflags = []

# library
if host_machine.system() == 'linux'
  common_ldflags += [ '-Wl,-z,relro', '-Wl,-z,now' ]
endif

lib_type = get_option('default_library')
if lib_type == 'shared' 
    mir_core_soname = 'lib@0@.so.@1@'.format(meson.project_name(), major_version)
    common_ldflags += ['-shared' ]
    if dc.get_id() == 'llvm'
        common_ldflags += [ '-soname', mir_core_soname ]
    endif 
endif


iopipe_lib = library(meson.project_name(),
    sources,
    include_directories: inc_dir,
    link_args : common_ldflags,
    install: true,
    version: meson.project_version(),
)

io_dep = dependency('io', fallback: ['io', 'io_dep'])

iopipe_dep = declare_dependency(
    link_with: [iopipe_lib],
    include_directories: inc_dir,
    dependencies: [io_dep],
)

# Compat variables for pkgconfig
pkg = import('pkgconfig')
pkg.generate(iopipe_lib,
    description: 'D language library for modular io',
    subdirs: 'd/' + meson.project_name(),
    url: 'https://github.com/schveiguy/iopipe'
)


install_subdir('source/',
    strip_directory : true,
    install_dir: 'include/d/' + meson.project_name(),
)
