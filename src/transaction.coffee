{find} = require 'underscore'
BufferPatch = require './buffer-patch'

module.exports =
class Transaction
  constructor: (@patches=[]) ->

  push: (patch) ->
    @patches.push(patch)

  invert: (textBuffer) ->
    new @constructor(@patches.map((patch) -> patch.invert(textBuffer)).reverse())

  applyTo: (textBuffer) ->
    patch.applyTo(textBuffer) for patch in @patches

  hasBufferPatches: ->
    find @patches, (patch) -> patch instanceof BufferPatch
