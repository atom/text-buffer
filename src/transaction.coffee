{find} = require 'underscore'
Serializable = require 'serializable'
BufferPatch = require './buffer-patch'

# Private: Contains several patches that we want to undo/redo as a batch.
module.exports =
class Transaction extends Serializable
  constructor: (@patches=[]) ->

  serializeParams: ->
    patches: @patches.map (patch) -> patch.serialize()

  deserializeParams: (params) ->
    params.patches = params.patches.map (patchState) -> BufferPatch.deserialize(patchState)
    params

  push: (patch) ->
    @patches.push(patch)

  invert: (buffer) ->
    new @constructor(@patches.map((patch) -> patch.invert(buffer)).reverse())

  applyTo: (buffer) ->
    patch.applyTo(buffer) for patch in @patches

  hasBufferPatches: ->
    find @patches, (patch) -> patch instanceof BufferPatch
