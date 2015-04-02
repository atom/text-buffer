Serializable = require 'serializable'
Range = require './range'

# Represents a single change to {TextBuffer}. We reify the change into an object
# so it can be stored in the undo/redo stack of {History}.
module.exports =
class BufferPatch extends Serializable
  constructor: (@oldRange, @newRange, @oldText, @newText, @normalizeLineEndings) ->

  serializeParams: ->
    oldRange = @oldRange.serialize()
    newRange = @newRange.serialize()
    {oldRange, newRange, @oldText, @newText, @normalizeLineEndings}

  deserializeParams: (params) ->
    params.oldRange = Range.deserialize(params.oldRange)
    params.newRange = Range.deserialize(params.newRange)
    params

  invert: (buffer) ->
    new @constructor(@newRange, @oldRange, @newText, @oldText, @normalizeLineEndings)

  applyTo: (buffer) ->
    buffer.applyPatch(this)
