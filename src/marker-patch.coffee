{clone} = require 'underscore-plus'
Serializable = require 'serializable'
Range = require './range'

# Private: Represents changes to a {Marker}. These patches are thrown away for
# standalone marker updates, but we reify marker changes into objects so they
# can be stored within {BufferPatch}es and {Transaction}s.
module.exports =
class MarkerPatch extends Serializable
  constructor: (@id, @oldParams, @newParams) ->

  serializeParams: ->
    oldParams = clone(@oldParams)
    oldParams.range = @oldParams.range.serialize()
    newParams = clone(@newParams)
    newParams.range = @newParams.range.serialize()
    {@id, oldParams, newParams}

  deserializeParams: (params) ->
    params.oldParams.range = Range.deserialize(params.oldParams.range)
    params.newParams.range = Range.deserialize(params.newParams.range)

  invert: ->
    new @constructor(@id, @newParams, @oldParams)

  applyTo: (buffer) ->
    buffer.getMarker(@id)?.update(@newParams)
