package = "lua-avro"
version = "0.6"

source = {
   url = "git@git.redjack.com:fathom/lua-avro.git",
   tag = "0.6"
}

description = {
   summary = "Lua bindings for Avro C library",
   homepage = "http://git.redjack.com/fathom/lua-avro",
   license = "Proprietary"
}

dependencies = {
   "lua >= 5.1",
}

external_dependencies = {
   AVRO = {
      header = "avro.h",
   },
}

build = {
   type = "builtin",
   modules = {
      avro = "src/avro.lua",
      ["avro.constants"] = "src/avro/constants.lua",
      ["avro.wrapper"] = "src/avro/wrapper.lua",
      ["avro.c"] = "src/avro/c.lua",
      ["avro.c.legacy"] = {
         sources = {"src/avro/c/legacy.c"},
         libraries = {"avro"},
         incdirs = {"$(AVRO_INCDIR)"},
         libdirs = {"$(AVRO_LIBDIR)"},
      },
      ["avro.c.ffi"] = "src/avro/c/ffi.lua",
      ["avro.test"] = "src/avro/test.lua",
      ["avro.tests.raw"] = "src/avro/tests/raw.lua",
      ["avro.tests.wrapper"] = "src/avro/tests/wrapper.lua",
   },
}
