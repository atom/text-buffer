module.exports =
class BufferPatch
  constructor: (@oldRange, @newRange, @oldText, @newText) ->

  invert: ->
    new @constructor(@newRange, @oldRange, @newText, @oldText)

  applyTo: (textBuffer) ->
    textBuffer.applyPatch(this)
