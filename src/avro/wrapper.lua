-- -*- coding: utf-8 -*-
------------------------------------------------------------------------
-- Copyright © 2011, RedJack, LLC.
-- All rights reserved.
--
-- Please see the LICENSE.txt file in this distribution for license
-- details.
------------------------------------------------------------------------

local ACC = require "avro.constants"

local assert = assert
local getmetatable = getmetatable
local error = error
local ipairs = ipairs
local next = next
local pairs = pairs
local print = print
local rawequal = rawequal
local rawset = rawset
local setmetatable = setmetatable
local string = string
local table = table
local tostring = tostring
local type = type

local ffi_present = pcall(require, "ffi")

module "avro.wrapper"

-- This module provides a framework for creating wrapper classes around
-- the raw Avro values returned by the avro.c module.  We provide a
-- couple of default wrapper classes.  For compound values (arrays,
-- maps, records, and unions), the default wrapper implements a nice
-- table-like syntax for accessing the child values.  For scalar values,
-- the default wrapper is a Lua scalar that has the same value as the
-- underlying Avro value.  Together, this lets you access the contents
-- of a value (named "value"), whose schema is
--
--   record test
--     long  ages[];
--   end
--
-- as "value.ages[2]", and have the result be a Lua number.
--
-- In addition to these default wrappers, you can install your own
-- wrapper classes.  A wrapper is defined by a subclass of the
-- predefined Wrapper class.  You should override the following
-- functions:
--
--   new_wrapper()
--     Return a new, empty wrapper instance for the given raw value.
--
--   wrap(raw_value)
--     Causes self.wrapped (a wrapper instance) to wrap the given raw Avro
--     value.  The function should always return the wrapper instance,
--     which does not have to be the same as self.
--
--   fill_from(wrapper)
--     Fills in the current raw Avro value with the contents of the
--     wrapper instance.  (If the wrapper instance is already directly
--     wrapping that raw value, then you don't need to do anything.)
--     wrapper can also be an arbitrary Lua value, in which case you
--     should pass in self to raw_value:set_from_ast().
--
--   tostring()
--     Returns a human-readable string description of the wrapped value.
--
-- Each wrapper class is associated with a named Avro schema.  This
-- means that there can only be a single wrapper class for any of the
-- non-named types (boolean, bytes, double, float, int, long, null,
-- string, array, map, and union).  If you need to provide a custom
-- wrapper class for one of these types, you must wrap it in a named
-- record.


------------------------------------------------------------------------
-- Wrapper superclass

Wrapper = {}
Wrapper.__name = "Wrapper"
Wrapper.__mt = { __class=Wrapper, __index=Wrapper }

local function get_class(self)
   return getmetatable(self).__class
end

function Wrapper:subclass(name)
   local class = {}
   class.__name = name
   class.__mt = {}
   for k,v in pairs(self.__mt) do
      class.__mt[k] = v
   end
   class.__mt.__class = class
   if type(class.__mt.__index) == "table" then
      class.__mt.__index = class
   end
   return setmetatable(class, { __index=self })
end

function Wrapper:new()
   local obj = {
      wrapped=self:new_wrapped(),
   }
   return setmetatable(obj, self.__mt)
end

function Wrapper:new_wrapped()
   error("Don't know how to create an instance of "..self.__name)
end

function Wrapper:tostring()
   return tostring(self.wrapped)
end

function Wrapper.__mt:__tostring()
   return self:tostring()
end

function Wrapper:wrap(raw_value)
   error("Don't know how to wrap raw value for "..self.__name)
end

function Wrapper:fill_from(wrapped)
   error("Don't know how to fill in raw value for "..self.__name)
end


------------------------------------------------------------------------
-- Wrapper dispatch table

-- These will be filled in below
local ScalarValue = Wrapper:subclass("ScalarValue")
local StringValue = Wrapper:subclass("StringValue")
local LongValue = Wrapper:subclass("LongValue")

local WRAPPERS = {}

local SCALAR_WRAPPERS = {
   boolean = ScalarValue,
   bytes = StringValue,
   double = ScalarValue,
   float = ScalarValue,
   int = ScalarValue,
   long = LongValue,
   null = ScalarValue,
   string = StringValue,
   enum = ScalarValue,
   fixed = StringValue,
}

function get_wrapper_class(schema)
   local schema_name = schema:name()

   if WRAPPERS[schema_name] then
      return WRAPPERS[schema_name]
   end

   if SCALAR_WRAPPERS[schema_name] then
      return SCALAR_WRAPPERS[schema_name]
   end

   return new_compound_wrapper(schema)
end

function set_wrapper_class(schema_name, wrapper)
   WRAPPERS[schema_name] = wrapper
end

function get_wrapper(raw)
   local schema = raw:schema()
   local class = get_wrapper_class(schema)
   local wrapped = class:new()
   return wrapped, wrapped:wrap(raw)
end


------------------------------------------------------------------------
-- Default scalar value wrappers

function ScalarValue:new_wrapped()
   return nil
end

function ScalarValue:wrap(raw_value)
   self.raw = raw_value
   self.wrapped = raw_value:get()
   return self.wrapped
end

function ScalarValue:fill_from(wrapped)
   self.raw:set(wrapped)
   self.wrapped = wrapped
end

StringValue.new_wrapped = ScalarValue.new_wrapped
StringValue.wrap = ScalarValue.wrap
StringValue.fill_from = ScalarValue.fill_from

function StringValue:tostring()
   return string.format("%q", self.wrapped)
end

LongValue.new_wrapped = ScalarValue.new_wrapped
LongValue.wrap = ScalarValue.wrap
LongValue.fill_from = ScalarValue.fill_from

if ffi_present then
   function LongValue:tostring()
      -- LuaJIT adds a "LL" suffix to the string representation of an
      -- int64
      return string.sub(tostring(self.wrapped), 1, -3)
   end
end


------------------------------------------------------------------------
-- Compound value superclass

local MEMOIZED_CLASSES = {}

CompoundValue = Wrapper:subclass("CompoundValue")

function CompoundValue:cmp(other)
   return self.raw:cmp(other.raw)
end

function CompoundValue:copy_from(other)
   return self.raw:copy_from(other.raw)
end

function CompoundValue:hash()
   return self.raw:hash()
end

function CompoundValue:release()
   self.raw:release()
   self.children = {}
end

function CompoundValue:reset()
   self.raw:reset()
   self.children = {}
end

function CompoundValue:set_from_ast(ast)
   return self.raw:set_from_ast(ast)
end

function CompoundValue:to_json()
   return self.raw:to_json()
end

function CompoundValue:type()
   return self.raw:type()
end

function CompoundValue.__mt:__lt(other)
   return self.raw < other.raw
end

function CompoundValue.__mt:__le(other)
   return self.raw <= other.raw
end

function CompoundValue.__mt:__eq(other)
   return self.raw == other.raw
end


function CompoundValue:new()
   local obj = { raw=nil, children={} }
   return setmetatable(obj, self.__mt)
end

function CompoundValue:wrap(raw_value)
   rawset(self, "raw", raw_value)
   return self
end

function CompoundValue:fill_from(wrapped)
   if getmetatable(wrapped) == self.__mt then
      if not rawequal(self.raw, wrapped) then
         self.raw:copy_from(wrapped)
      end
   else
      self.raw:set_from_ast(wrapped)
   end
end


------------------------------------------------------------------------
-- Array

ArrayValue = CompoundValue:subclass("ArrayValue")

function ArrayValue:get_child(idx)
   if not self.children[idx] then
      self.children[idx] = assert(self.__child_class:new())
   end
   return self.children[idx]
end

function ArrayValue:get(index)
   local raw_child, err = self.raw:get(index)
   if not raw_child then return raw_child, err end
   local child = self:get_child(index)
   return child:wrap(raw_child)
end

function ArrayValue:append(val)
   local raw_child, err = self.raw:append()
   if not raw_child then return raw_child, err end

   local idx = self.raw:size()
   local child = self:get_child(idx)
   local wrapper = child:wrap(raw_child)
   if val then
      child:fill_from(val)
   else
      return wrapper
   end
end

local function iterate_wrapped(state, unused)
   local k,v = state.f(state.s, state.var)
   if not k then return k,v end
   state.var = k
   local child = state.self:get_child(k)
   return k, child:wrap(v)
end

function ArrayValue:iterate(want_raw)
   if want_raw then
      return self.raw:iterate()
   else
      local f, s, var = self.raw:iterate()
      local state = { f=f, s=s, var=var, self=self }
      return iterate_wrapped, state, nil
   end
end

function ArrayValue:tostring()
   local elements = {}
   for i, _ in self:iterate() do
      local child = self:get_child(i)
      table.insert(elements, child:tostring())
   end
   return "["..table.concat(elements, ", ").."]"
end

function ArrayValue.__mt:__index(idx)
   -- First try a class method.
   local result = get_class(self)[idx]
   if result then return result end

   -- Otherwise mimic the get() method
   return self:get(idx)
end

function ArrayValue.__mt:__newindex(idx, val)
   -- If there's a class method with this name, you can't use the table
   -- syntax.
   if get_class(self)[idx] then
      error("Cannot set "..tostring(idx).." with [] syntax")
   end

   -- Otherwise mimic the non-existent set() method
   local raw_child, err = self.raw:get(idx)
   if not raw_child then return raw_child, err end
   local child = self:get_child(idx)
   child:wrap(raw_child)
   child:fill_from(val)
end

local function array_class(schema)
   local class = ArrayValue:subclass(schema:name())
   MEMOIZED_CLASSES[schema:id()] = class

   local child_schema = schema:item_schema()
   local child_class = assert(get_wrapper_class(child_schema))
   class.__child_class = child_class
   return class
end


------------------------------------------------------------------------
-- Map

MapValue = CompoundValue:subclass("MapValue")

function MapValue:get_child(idx)
   if not self.children[idx] then
      self.children[idx] = assert(self.__child_class:new())
   end
   return self.children[idx]
end

function MapValue:get(index)
   local raw_child, err = self.raw:get(index)
   if not raw_child then return raw_child, err end
   local child = self:get_child(index)
   return child:wrap(raw_child)
end

function MapValue:add(key, val)
   local raw_child = self.raw:add(key)
   local child = self:get_child(key)
   local wrapper = child:wrap(raw_child)
   if val then
      child:fill_from(val)
   else
      return wrapper
   end
end

MapValue.set = MapValue.add

function MapValue:iterate(want_raw)
   if want_raw then
      return self.raw:iterate()
   else
      local f, s, var = self.raw:iterate()
      local state = { f=f, s=s, var=var, self=self }
      return iterate_wrapped, state, nil
   end
end

function MapValue:tostring()
   local elements = {}
   for key, _ in self:iterate() do
      local child = self:get_child(key)
      local entry = string.format("%q: %s", key, child:tostring())
      table.insert(elements, entry)
   end
   return "{"..table.concat(elements, ", ").."}"
end

function MapValue.__mt:__index(idx)
   -- First try a class method.
   local result = get_class(self)[idx]
   if result then return result end

   -- Otherwise mimic the add() method
   return self:add(idx)
end

function MapValue.__mt:__newindex(idx, val)
   -- If there's a class method with this name, you can't use the table
   -- syntax.
   if get_class(self)[idx] then
      error("Cannot set "..tostring(idx).." with [] syntax")
   end

   -- Otherwise mimic the add() method
   self:add(idx, val)
end

local function map_class(schema)
   local class = MapValue:subclass(schema:name())
   MEMOIZED_CLASSES[schema:id()] = class

   local child_schema = schema:value_schema()
   local child_class = assert(get_wrapper_class(child_schema))
   class.__child_class = child_class
   return class
end


------------------------------------------------------------------------
-- Record

RecordValue = CompoundValue:subclass("RecordValue")

function RecordValue:get_child(idx)
   local real_index = self.__real_indices[idx]
   if not real_index then
      error("No field "..tostring(idx))
   end

   if not self.children[real_index] then
      self.children[real_index] = self.__child_classes[real_index]:new()
   end
   return self.children[real_index], real_index
end

function RecordValue:get(idx)
   local child, real_index = self:get_child(idx)
   local raw_child, err = self.raw:get(real_index)
   if not raw_child then return raw_child, err end
   return child:wrap(raw_child)
end

function RecordValue:set(idx, val)
   local child, real_index = self:get_child(idx)
   local raw_child, err = self.raw:get(real_index)
   if not raw_child then return raw_child, err end
   child:wrap(raw_child)
   child:fill_from(val)
end

function RecordValue:tostring()
   local field_str = {}
   for i, field_table in ipairs(fields) do
      local field_name, _ = next(field_table)
      assert(self:get(i))
      local entry =
         string.format("%s: %s", field_name, self.children[i]:tostring())
      table.insert(field_str, entry)
   end
   return "{"..table.concat(field_str, ", ").."}"
end

function RecordValue.__mt:__index(idx)
   -- First try a class method.
   local result = get_class(self)[idx]
   if result then return result end

   -- Otherwise see if there's a field with this name or index.
   return assert(RecordValue.get(self, idx))
end

function RecordValue.__mt:__newindex(idx, val)
   -- If there's a class method with this name, you can't use the
   -- table syntax.
   if get_class(self)[idx] then
      error("Cannot set "..tostring(idx).." with [] syntax")
   end

   -- Otherwise mimic the set() method
   local child, real_index = self:get_child(idx)
   local raw_child, err = self.raw:get(real_index)
   if not raw_child then return raw_child, err end
   child:wrap(raw_child)
   child:fill_from(val)
end

local function record_class(schema)
   local class = RecordValue:subclass(schema:name())
   MEMOIZED_CLASSES[schema:id()] = class

   local fields = schema:fields()
   local child_classes = {}
   local real_indices = {}
   for i, field_table in ipairs(fields) do
      local field_name, field_schema = next(field_table)
      local child_class = assert(get_wrapper_class(field_schema))
      child_classes[i] = child_class
      child_classes[field_name] = child_class
      real_indices[i] = i
      real_indices[field_name] = i
   end

   class.__child_classes = child_classes
   class.__real_indices = real_indices
   return class
end


------------------------------------------------------------------------
-- Union

UnionValue = CompoundValue:subclass("UnionValue")

function UnionValue:get_child(idx)
   local real_index = self.__real_indices[idx]
   if not real_index then
      error("No branch "..tostring(idx))
   end

   if not self.children[real_index] then
      self.children[real_index] = self.__child_classes[real_index]:new()
   end
   return self.children[real_index], real_index
end

function UnionValue:get(index)
   if index then
      local child, real_index = self:get_child(index)
      local raw_child, err = self.raw:get(real_index)
      if not raw_child then return raw_child, err end
      return child:wrap(raw_child)
   else
      index = self.raw:discriminant_index()
      local raw_child, err = self.raw:get()
      if not raw_child then return raw_child, err end
      local child = self:get_child(index)
      return child:wrap(raw_child)
   end
end

function UnionValue:set(index, val)
   local child, real_index = self:get_child(idx)
   local raw_child, err = self.raw:set(real_index)
   if not raw_child then return raw_child, err end
   child:wrap(raw_child)
   if val then
      child:fill_from(val)
   end
end

function UnionValue:discriminant_index()
   return self.raw:discriminant_index()
end

function UnionValue:discriminant()
   return self.raw:discriminant()
end

function UnionValue:tostring()
   local branch_name = self.raw:discriminant()
   if branch_name == "null" then
      return branch_name
   else
      local index = self.raw:discriminant_index()
      local child = self:get_child(index)
      local raw_child = self.raw:get()
      child:wrap(raw_child)
      return string.format("<%s> %s", branch_name, child:tostring())
   end
end

function UnionValue.__mt:__index(idx)
   -- First try a class method.
   local result = get_class(self)[idx]
   if result then return result end

   -- The special "_" field represents the current active branch.
   if idx == "_" then
      return self:get()
   else
      return self:get(idx)
   end
end

function UnionValue.__mt:__newindex(idx, val)
   -- If there's a class method with this name, you can't use the table
   -- syntax.
   if get_class(self)[idx] then
      error("Cannot set "..tostring(idx).." with [] syntax")
   end

   -- The special "_" field represents the current active branch.
   if idx == "_" then
      idx = self.raw:discriminant_index()
      local raw_child, err = self.raw:get()
      if not raw_child then return raw_child, err end
      local child = self:get_child(idx)
      child:wrap(raw_child)
      child:fill_from(val)
   else
      local child, real_index = self:get_child(idx)
      local raw_child, err = self.raw:get(real_index)
      if not raw_child then return raw_child, err end
      child:wrap(raw_child)
      child:fill_from(val)
   end
end

local function union_class(schema)
   local class = UnionValue:subclass(schema:name())
   MEMOIZED_CLASSES[schema:id()] = class

   local branches = schema:branches()
   local child_classes = {}
   local real_indices = {}
   for i, branch_table in ipairs(branches) do
      local branch_name, branch_schema = next(branch_table)
      local child_class = assert(get_wrapper_class(branch_schema))
      child_classes[i] = child_class
      child_classes[branch_name] = child_class
      real_indices[i] = i
      real_indices[branch_name] = i
   end

   class.__child_classes = child_classes
   class.__real_indices = real_indices
   return class
end


------------------------------------------------------------------------
-- Compound wrappers

function new_compound_wrapper(schema)
   -- Links are handled specially.
   local schema_type = schema:type()
   if schema_type == ACC.LINK then
      return new_compound_wrapper(schema:link_target())
   end

   -- See if we've already created a wrapper for this schema.
   local schema_id = schema:id()
   if MEMOIZED_CLASSES[schema_id] then
      return MEMOIZED_CLASSES[schema_id]
   end

   -- Otherwise create a new one.

   if schema_type == ACC.ARRAY then
      return array_class(schema)
   elseif schema_type == ACC.MAP then
      return map_class(schema)
   elseif schema_type == ACC.RECORD then
      return record_class(schema)
   elseif schema_type == ACC.UNION then
      return union_class(schema)
   end
end
