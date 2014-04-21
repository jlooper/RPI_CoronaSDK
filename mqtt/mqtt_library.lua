-- mqtt_library.lua
-- ~~~~~~~~~~~~~~~~
-- Please do not remove the following notices.
-- Copyright (c) 2011 by Geekscape Pty. Ltd.
-- License: AGPLv3 http://geekscape.org/static/aiko_license.html
-- Version: 0.0 2011-07-28

---
-- @module mqtt_library
--
-- Documentation
-- ~~~~~~~~~~~~~
-- MQTT Lua web-site
--   http://geekscape.github.com/mqtt_lua
--
-- MQTT Lua repository notes
--   https://github.com/geekscape/mqtt_lua/blob/master/readme.markdown
--
-- Aiko Platform web-site
--   https://sites.google.com/site/aikoplatform
--
-- References
-- ~~~~~~~~~~
-- MQTT web-site
--   http://mqtt.org

-- MQTT protocol specification 3.1
--   https://www.ibm.com/developerworks/webservices/library/ws-mqtt
--
-- Notes
-- ~~~~~
-- - Always assumes MQTT connection "clean session" enabled.
-- - Supports connection last will and testament message.
-- - Does not support connection username and password.
-- - Fixed message header byte 1, only implements the "message type".
-- - Only supports QOS level 0.
-- - Maximum payload length is 127 bytes (easily increased).
-- - Publish message doesn't support "message identifier".
-- - Subscribe acknowledgement messages don't check granted QOS level.
-- - Outstanding subscribe acknowledgement messages aren't escalated.
-- - Works on the Sony PlayStation Portable (aka Sony PSP) ...
--     See http://en.wikipedia.org/wiki/Lua_Player_HM
--
-- ToDo
-- ~~~~
-- - Consider use of assert() and pcall() ?
-- - Fix problem when KEEP_ALIVE_TIME is short, e.g. mqtt_publish -k 1
--     MQTT.client:handler(): Message length mismatch
-- - Only expose public API functions, don't expose internal API functions.
-- - Refactor "if self.connected()" to "self.checkConnected(error_message)".
-- - Memory heap/stack monitoring.
-- - Implement parse PUBACK message.
-- - When debugging, why isn't mosquitto sending back CONACK error code ?
-- - On socket error, optionally try reconnection to MQTT server.
-- - Maintain and publish messaging statistics.
-- - Increase maximum payload length to 16,383 or larger ?
-- - Handle failed subscriptions, i.e no subscription acknowledgement received.
-- - Subscription callbacks invoked by topic name (including wildcards).
-- - Implement asynchronous state machine, rather than single-thread waiting.
--   - After CONNECT, expect and wait for a CONACK.
-- - Implement complete MQTT broker (server)
-- - Consider using Copas http://keplerproject.github.com/copas/manual.html
-- ------------------------------------------------------------------------- --

function isPsp() return(Socket ~= nil) end

if (not isPsp()) then
  require("socket")
  require("io")
  require("ltn12")
--require("ssl")
end

local MQTT = {}

---
-- @field [parent = #mqtt_library] utility#utility Utility
--
MQTT.Utility = require("mqtt.utility")

---
-- @field [parent = #mqtt_library] #number VERSION
--
MQTT.VERSION = 0x03

---
-- @field [parent = #mqtt_library] #boolean ERROR_TERMINATE
--
MQTT.ERROR_TERMINATE = false      -- Message handler errors terminate process ?

---
-- @field [parent = #mqtt_library] #string DEFAULT_BROKER_HOSTNAME
--
MQTT.DEFAULT_BROKER_HOSTNAME = "test.mosquitto.org"

---
-- An MQTT client
-- @type client

---
-- @field [parent = #mqtt_library] #client client
--
MQTT.client = {}
MQTT.client.__index = MQTT.client


---
-- @field [parent = #client] #number DEFAULT_PORT
--
MQTT.client.DEFAULT_PORT       = 1883

---
-- @field [parent = #client] #number KEEP_ALIVE_TIME
--
MQTT.client.KEEP_ALIVE_TIME    =   60  -- seconds (maximum is 65535)

---
-- @field [parent = #client] #number MAX_PAYLOAD_LENGTH
--
MQTT.client.MAX_PAYLOAD_LENGTH =  127


-- MQTT 3.1 Specification: Section 2.1: Fixed header, Message type

---
-- @field [parent = #mqtt_library] message
--
MQTT.message = {}
MQTT.message.TYPE_RESERVED    = 0x00
MQTT.message.TYPE_CONNECT     = 0x01
MQTT.message.TYPE_CONACK      = 0x02
MQTT.message.TYPE_PUBLISH     = 0x03
MQTT.message.TYPE_PUBACK      = 0x04
MQTT.message.TYPE_PUBREC      = 0x05
MQTT.message.TYPE_PUBREL      = 0x06
MQTT.message.TYPE_PUBCOMP     = 0x07
MQTT.message.TYPE_SUBSCRIBE   = 0x08
MQTT.message.TYPE_SUBACK      = 0x09
MQTT.message.TYPE_UNSUBSCRIBE = 0x0a
MQTT.message.TYPE_UNSUBACK    = 0x0b
MQTT.message.TYPE_PINGREQ     = 0x0c
MQTT.message.TYPE_PINGRESP    = 0x0d
MQTT.message.TYPE_DISCONNECT  = 0x0e
MQTT.message.TYPE_RESERVED    = 0x0f

-- MQTT 3.1 Specification: Section 3.2: CONACK acknowledge connection errors

MQTT.CONACK = {}
MQTT.CONACK.error_message = {          -- CONACK return code used as the index
  "Unacceptable protocol version",
  "Identifer rejected",
  "Server unavailable",
  "Bad user name or password",
  "Not authorized"
}

-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Create an MQTT client instance
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

---
-- Create an MQTT client instance.
-- @param #string hostname Host name or address of the MQTT broker
-- @param #number port Port number of the MQTT broker (default: 1883)
-- @param #function callback Invoked when subscribed topic messages received
-- @function [parent = #client] create
-- @return #client created client
--
function MQTT.client.create(                                      -- Public API
  hostname,  -- string:   Host name or address of the MQTT broker
  port,      -- integer:  Port number of the MQTT broker (default: 1883)
  callback)  -- function: Invoked when subscribed topic messages received

  local mqtt_client = {}

  setmetatable(mqtt_client, MQTT.client)

  mqtt_client.callback = callback  -- function(topic, payload)
  mqtt_client.hostname = hostname
  mqtt_client.port     = port or MQTT.client.DEFAULT_PORT

  mqtt_client.connected     = false
  mqtt_client.last_activity = 0
  mqtt_client.message_id    = 0
  mqtt_client.outstanding   = {}
  mqtt_client.socket_client = nil

  return(mqtt_client)
end

--- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Transmit MQTT Client request a connection to an MQTT broker (server).
-- MQTT 3.1 Specification: Section 3.1: CONNECT
-- @param self
-- @param #string identifier MQTT client identifier (maximum 23 characters)
-- @param #string will_topic Last will and testament topic
-- @param #string will_qos Last will and testament Quality Of Service
-- @param #string will_retain Last will and testament retention status
-- @param #string will_message Last will and testament message
-- @function [parent = #client] connect
--
function MQTT.client:connect(                                     -- Public API
  identifier,    -- string: MQTT client identifier (maximum 23 characters)
  will_topic,    -- string: Last will and testament topic
  will_qos,      -- byte:   Last will and testament Quality Of Service
  will_retain,   -- byte:   Last will and testament retention status
  will_message)  -- string: Last will and testament message

  if (self.connected) then
    error("MQTT.client:connect(): Already connected")
  end

  MQTT.Utility.debug("MQTT.client:connect(): " .. identifier)

  self.socket_client = socket.connect(self.hostname, self.port)

  if (self.socket_client == nil) then
    error("MQTT.client:connect(): Couldn't open MQTT broker connection")
  end

  MQTT.Utility.socket_wait_connected(self.socket_client)

  self.connected = true

-- Construct CONNECT variable header fields (bytes 1 through 9)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  local payload
  payload = MQTT.client.encode_utf8("MQIsdp")
  payload = payload .. string.char(MQTT.VERSION)

-- Connect flags (byte 10)
-- ~~~~~~~~~~~~~
-- bit    7: Username flag =  0  -- recommended no more than 12 characters
-- bit    6: Password flag =  0  -- ditto
-- bit    5: Will retain   =  0
-- bits 4,3: Will QOS      = 00
-- bit    2: Will flag     =  0
-- bit    1: Clean session =  1
-- bit    0: Unused        =  0

  if (will_topic == nil) then
    payload = payload .. string.char(0x02)       -- Clean session, no last will
  else
    local flags
    flags = MQTT.Utility.shift_left(will_retain, 5)
    flags = flags + MQTT.Utility.shift_left(will_qos, 3) + 0x06
    payload = payload .. string.char(flags)
  end

-- Keep alive timer (bytes 11 LSB and 12 MSB, unit is seconds)
-- ~~~~~~~~~~~~~~~~~
  payload = payload .. string.char(MQTT.client.KEEP_ALIVE_TIME / 256)
  payload = payload .. string.char(MQTT.client.KEEP_ALIVE_TIME % 256)

-- Client identifier
-- ~~~~~~~~~~~~~~~~~
  payload = payload .. MQTT.client.encode_utf8(identifier)

-- Last will and testament
-- ~~~~~~~~~~~~~~~~~~~~~~~
  if (will_topic ~= nil) then
    payload = payload .. MQTT.client.encode_utf8(will_topic)
    payload = payload .. MQTT.client.encode_utf8(will_message)
  end

-- Send MQTT message
-- ~~~~~~~~~~~~~~~~~
  self:message_write(MQTT.message.TYPE_CONNECT, payload)
end

--- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Destroy an MQTT client instance.
-- @param self
-- @function [parent = #client] destroy
--
function MQTT.client:destroy()                                    -- Public API

  MQTT.Utility.debug("MQTT.client:destroy()")

  if (self.connected) then self:disconnect() end

  self.callback = nil
  self.outstanding = nil
end

--- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Transmit MQTT Disconnect message.
-- MQTT 3.1 Specification: Section 3.14: Disconnect notification
-- bytes 1,2: Fixed message header, see MQTT.client:message_write()
-- @param self
-- @function [parent = #client] disconnect
--

function MQTT.client:disconnect()                                 -- Public API
  MQTT.Utility.debug("MQTT.client:disconnect()")

  if (self.connected) then
    self:message_write(MQTT.message.TYPE_DISCONNECT, nil)
    self.socket_client:close()
    self.connected = false
  else
    error("MQTT.client:disconnect(): Already disconnected")
  end
end

-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Encode a message string using UTF-8 (for variable header)
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- MQTT 3.1 Specification: Section 2.5: MQTT and UTF-8
--
-- byte  1:   String length MSB
-- byte  2:   String length LSB
-- bytes 3-n: String encoded as UTF-8

function MQTT.client.encode_utf8(                               -- Internal API
  input)  -- string

  local output
  output = string.char(#input / 256)
  output = output .. string.char(#input % 256)
  output = output .. input

  return(output)
end

--- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Handle received messages and maintain keep-alive PING messages.
-- This function must be invoked periodically (more often than the
-- `MQTT.client.KEEP_ALIVE_TIME`) which maintains the connection and
-- services the incoming subscribed topic messages
-- @param self
-- @function [parent = #client] handler
--
function MQTT.client:handler()                                    -- Public API
  if (self.connected == false) then
    error("MQTT.client:handler(): Not connected")
  end

  MQTT.Utility.debug("MQTT.client:handler()")

-- Transmit MQTT PING message
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~
-- MQTT 3.1 Specification: Section 3.13: PING request
--
-- bytes 1,2: Fixed message header, see MQTT.client:message_write()

  local activity_timeout = self.last_activity + MQTT.client.KEEP_ALIVE_TIME

  if (MQTT.Utility.get_time() > activity_timeout) then
    MQTT.Utility.debug("MQTT.client:handler(): PINGREQ");

    self:message_write(MQTT.message.TYPE_PINGREQ, nil)
  end

-- Check for available client socket data
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  local error_state = MQTT.Utility.socket_data_available(self.socket_client)

  if (error_state ~= "timeout") then
    local buffer, error_message =
      MQTT.Utility.socket_receive(self.socket_client)

    if (error_message == "error") then
      self:destroy()
      error("socket_client:receive(): " .. error_message)
    end

    if (buffer ~= nil and #buffer > 0) then
      local index = 1

      -- Parse individual messages (each must be at least 2 bytes long)

      while (index < #buffer) do
        local message_length = string.byte(buffer, index + 1) + 2
        local message = string.sub(buffer, index, index + message_length - 1)
        index = index + message_length

        self:parse_message(message)
      end

      -- Check for any left over bytes, i.e. partial message received

      if (index ~= (#buffer + 1)) then
        local error_message =
          "MQTT.client:handler(): Message length mismatch" ..
          index .. " ~= " .. (#buffer + 1)

        if (MQTT.ERROR_TERMINATE) then         -- TODO: Refactor duplicate code
          self:destroy()
          error(error_message)
        else
          MQTT.Utility.debug(error_message)
        end
      end
    end
  end
end

-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Transmit an MQTT message
-- ~~~~~~~~~~~~~~~~~~~~~~~~
-- MQTT 3.1 Specification: Section 2.1: Fixed header
--
-- byte  1:   Message type and flags (DUP, QOS level, and Retain) fields
-- byte  2:   Remaining length field (at least one byte)
-- bytes 3-n: Optional variable header and payload

function MQTT.client:message_write(                             -- Internal API
  message_type,  -- enumeration
  payload)       -- string

-- TODO: Complete implementation of fixed header byte 1

  local message = string.char(MQTT.Utility.shift_left(message_type, 4))

  if (payload == nil) then
    message = message .. string.char(0)  -- Zero length, no payload
  else
    if (#payload > MQTT.client.MAX_PAYLOAD_LENGTH) then
      error(
        "MQTT.client:message_write(): Payload length = " .. #payload ..
        " exceeds maximum of " .. MQTT.client.MAX_PAYLOAD_LENGTH
      )
    end

    message = message .. string.char(#payload)
    message = message .. payload
  end

  local status, error_message = self.socket_client:send(message)

  if (status == nil) then
    self:destroy()
    error("MQTT.client:message_write(): " .. error_message)
  end

  self.last_activity = MQTT.Utility.get_time()
end

-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Parse MQTT message
-- ~~~~~~~~~~~~~~~~~~
-- MQTT 3.1 Specification: Section 2.1: Fixed header
--
-- byte  1:   Message type and flags (DUP, QOS level, and Retain) fields
-- byte  2:   Remaining length field (at least one byte)
-- bytes 3-n: Optional variable header and payload

function MQTT.client:parse_message(                             -- Internal API
  message)  -- string

  local message_type = MQTT.Utility.shift_right(string.byte(message), 4)

-- TODO: MQTT.message.TYPE table should include "parser handler" function.
--       This would nicely collapse the if .. then .. elseif .. end.

  if (message_type == MQTT.message.TYPE_CONACK) then
    self:parse_message_conack(message)

  elseif (message_type == MQTT.message.TYPE_PUBLISH) then
    self:parse_message_publish(message)

  elseif (message_type == MQTT.message.TYPE_PUBACK) then
    print("MQTT.client:parse_message(): PUBACK -- UNIMPLEMENTED --")    -- TODO

  elseif (message_type == MQTT.message.TYPE_SUBACK) then
    self:parse_message_suback(message)

  elseif (message_type == MQTT.message.TYPE_UNSUBACK) then
    self:parse_message_unsuback(message)

  elseif (message_type == MQTT.message.TYPE_PINGREQ) then
    self:ping_response()

  elseif (message_type == MQTT.message.TYPE_PINGRESP) then
    self:parse_message_pingresp(message)

  else
    local error_message =
      "MQTT.client:parse_message(): Unknown message type: " .. message_type

    if (MQTT.ERROR_TERMINATE) then             -- TODO: Refactor duplicate code
      self:destroy()
      error(error_message)
    else
      MQTT.Utility.debug(error_message)
    end
  end
end

-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Parse MQTT CONACK message
-- ~~~~~~~~~~~~~~~~~~~~~~~~~
-- MQTT 3.1 Specification: Section 3.2: CONACK Acknowledge connection
--
-- bytes 1,2: Fixed message header, see MQTT.client:parse_message()
-- byte  3  : Reserved value
-- byte  4  : Connect return code, see MQTT.CONACK.error_message[]

function MQTT.client:parse_message_conack(                      -- Internal API
  message)  -- string

  local me = "MQTT.client:parse_message_conack()"
  MQTT.Utility.debug(me)

  if (#message ~= 4) then
    error(me .. ": Invalid message length")
  end

  if (string.byte(message, 2) ~= 0x02) then
    error(me .. ": Invalid remaining length")
  end

  local return_code = string.byte(message, 4)

  if (return_code ~= 0x00) then
    local error_message = "Unknown return code"

    if (return_code <= table.getn(MQTT.CONACK.error_message)) then
      error_message = MQTT.CONACK.error_message[return_code]
    end

    error(me .. ": Connection refused: " .. error_message)
  end
end

-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Parse MQTT PINGRESP message
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- MQTT 3.1 Specification: Section 3.13: PING response
--
-- bytes 1,2: Fixed message header, see MQTT.client:parse_message()

function MQTT.client:parse_message_pingresp(                    -- Internal API
  message)  -- string

  local me = "MQTT.client:parse_message_pingresp()"
  MQTT.Utility.debug(me)

  if (#message ~= 2) then
    error(me .. ": Invalid message length")
  end

  if (string.byte(message, 2) ~= 0x00) then
    error(me .. ": Invalid remaining length")
  end
end

-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Parse MQTT PUBLISH message
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~
-- MQTT 3.1 Specification: Section 3.3: Publish message
--
-- bytes 1,2: Fixed message header, see MQTT.client:message_write()
--            Variable header ..
-- bytes 3- : Topic name and optional Message Identifier (if QOS > 0)
-- bytes m- : Payload

function MQTT.client:parse_message_publish(                     -- Internal API
  message)  -- string

  local me = "MQTT.client:parse_message_publish()"
  MQTT.Utility.debug(me)

  if (self.callback ~= nil) then
    if (#message < 5) then
      error(me .. ": Invalid message length: " .. #message)
    end

    local qos = MQTT.Utility.shift_left(string.byte(message, 1), 1) % 3

    local remaining_length = string.byte(message, 2)

    if (remaining_length < 3) then
      error(me .. ": Invalid remaining length: " .. remaining_length)
    end

    local topic_length = string.byte(message, 3) * 256 + string.byte(message, 4)
    local topic = string.sub(message, 5, topic_length + 4)

    local index = topic_length + 5

-- Handle optional Message Identifier, for QOS levels 1 and 2
-- TODO: Enable Subscribe with QOS and deal with PUBACK, etc.

    if (qos > 0) then
      local message_id = string.byte(message, index) * 256
      message_id = message_id + string.byte(message, index + 1)
      index = index + 2
    end

    local payload_length = remaining_length - index + 3
    local payload = string.sub(message, index, index + payload_length - 1)

    self.callback(topic, payload)
  end
end

-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Parse MQTT SUBACK message
-- ~~~~~~~~~~~~~~~~~~~~~~~~~
-- MQTT 3.1 Specification: Section 3.9: SUBACK Subscription acknowledgement
--
-- bytes 1,2: Fixed message header, see MQTT.client:parse_message()
-- bytes 3,4: Message Identifier
-- bytes 5- : List of granted QOS for each subscribed topic

function MQTT.client:parse_message_suback(                      -- Internal API
  message)  -- string

  local me = "MQTT.client:parse_message_suback()"
  MQTT.Utility.debug(me)

  if (#message < 5) then
    error(me .. ": Invalid message length: " .. #message)
  end

  local remaining_length = string.byte(message, 2)

  if (remaining_length < 3) then
    error(me .. ": Invalid remaining length: " .. remaining_length)
  end

  local message_id = string.byte(message, 3) * 256 + string.byte(message, 4)

  local outstanding = self.outstanding[message_id]

  if (outstanding == nil) then
    error(me .. ": No outstanding message: " .. message_id)
  end

  self.outstanding[message_id] = nil

  if (outstanding[1] ~= "subscribe") then
    error(me .. ": Outstanding message wasn't SUBSCRIBE")
  end

  local topic_count = table.getn(outstanding[2])

  if (topic_count + 2 ~= remaining_length) then
    error(me .. ": Didn't received expected number of topics: " .. topic_count)
  end
end

-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Parse MQTT UNSUBACK message
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- MQTT 3.1 Specification: Section 3.11: UNSUBACK Unsubscription acknowledgement
--
-- bytes 1,2: Fixed message header, see MQTT.client:parse_message()
-- bytes 3,4: Message Identifier

function MQTT.client:parse_message_unsuback(                    -- Internal API
  message)  -- string

  local me = "MQTT.client:parse_message_unsuback()"
  MQTT.Utility.debug(me)

  if (#message ~= 4) then
    error(me .. ": Invalid message length: " .. #message)
  end

  if (string.byte(message, 2) ~= 0x02) then
    error(me .. ": Invalid remaining length")
  end

  local message_id = string.byte(message, 3) * 256 + string.byte(message, 4)

  local outstanding = self.outstanding[message_id]

  if (outstanding == nil) then
    error(me .. ": No outstanding message: " .. message_id)
  end

  self.outstanding[message_id] = nil

  if (outstanding[1] ~= "unsubscribe") then
    error(me .. ": Outstanding message wasn't UNSUBSCRIBE")
  end
end

-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Transmit MQTT Ping response message
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- MQTT 3.1 Specification: Section 3.13: PING response
--
-- bytes 1,2: Fixed message header, see MQTT.client:message_write()

function MQTT.client:ping_response()                            -- Internal API
  MQTT.Utility.debug("MQTT.client:ping_response()")

  if (self.connected == false) then
    error("MQTT.client:ping_response(): Not connected")
  end

  self:message_write(MQTT.message.TYPE_PINGRESP, nil)
end

--- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Transmit MQTT Publish message.
-- MQTT 3.1 Specification: Section 3.3: Publish message
--
-- * bytes 1,2: Fixed message header, see MQTT.client:message_write()
--            Variable header ..
-- * bytes 3- : Topic name and optional Message Identifier (if QOS > 0)
-- * bytes m- : Payload
-- @param self
-- @param #string topic
-- @param #string payload
-- @function [parent = #client] publish
--
function MQTT.client:publish(                                     -- Public API
  topic,    -- string
  payload)  -- string

  if (self.connected == false) then
    error("MQTT.client:publish(): Not connected")
  end

  MQTT.Utility.debug("MQTT.client:publish(): " .. topic)

  local message = MQTT.client.encode_utf8(topic) .. payload

  self:message_write(MQTT.message.TYPE_PUBLISH, message)
end

--- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Transmit MQTT Subscribe message.
-- MQTT 3.1 Specification: Section 3.8: Subscribe to named topics
--
-- * bytes 1,2: Fixed message header, see MQTT.client:message_write()
--            Variable header ..
-- * bytes 3,4: Message Identifier
-- * bytes 5- : List of topic names and their QOS level
-- @param self
-- @param #string topics table of strings
-- @function [parent = #client] subscribe
--
function MQTT.client:subscribe(                                   -- Public API
  topics)  -- table of strings

  if (self.connected == false) then
    error("MQTT.client:subscribe(): Not connected")
  end

  self.message_id = self.message_id + 1

  local message
  message = string.char(self.message_id / 256)
  message = message .. string.char(self.message_id % 256)

  for index, topic in ipairs(topics) do
    MQTT.Utility.debug("MQTT.client:subscribe(): " .. topic)
    message = message .. MQTT.client.encode_utf8(topic)
    message = message .. string.char(2)  -- QOS level 0
  end

  self:message_write(MQTT.message.TYPE_SUBSCRIBE, message)

  self.outstanding[self.message_id] = { "subscribe", topics }
end

--- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - --
-- Transmit MQTT Unsubscribe message
-- MQTT 3.1 Specification: Section 3.10: Unsubscribe from named topics
--
-- * bytes 1,2: Fixed message header, see MQTT.client:message_write()
--            Variable header ..
-- * bytes 3,4: Message Identifier
-- * bytes 5- : List of topic names
-- @param self
-- @param #string topics table of strings
-- @function [parent = #client] unsubscribe
--
function MQTT.client:unsubscribe(                                 -- Public API
  topics)  -- table of strings

  if (self.connected == false) then
    error("MQTT.client:unsubscribe(): Not connected")
  end

  self.message_id = self.message_id + 1

  local message
  message = string.char(self.message_id / 256)
  message = message .. string.char(self.message_id % 256)

  for index, topic in ipairs(topics) do
    MQTT.Utility.debug("MQTT.client:unsubscribe(): " .. topic)
    message = message .. MQTT.client.encode_utf8(topic)
  end

  self:message_write(MQTT.message.TYPE_UNSUBSCRIBE, message)

  self.outstanding[self.message_id] = { "unsubscribe", topics }
end

-- For ... MQTT = require("mqtt_library")

return(MQTT)