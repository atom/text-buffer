{find} = require 'underscore-plus'
Serializable = require 'serializable'
BufferPatch = require './buffer-patch'
MarkerPatch = require './marker-patch'

# Contains several patches that we want to undo/redo as a batch.
module.exports =
class Transaction extends Serializable
  @registerDeserializers(BufferPatch, MarkerPatch)

  constructor: (@patches=[], groupingInterval=0) ->
    @groupingExpirationTime = Date.now() + groupingInterval

  serializeParams: ->
    patches: @patches.map (patch) -> patch.serialize()

  deserializeParams: (params) ->
    params.patches = params.patches.map (patchState) => @constructor.deserialize(patchState)
    params

  push: (patch) ->
    @patches.push(patch)

  invert: (buffer) ->
    new @constructor(@patches.map((patch) -> patch.invert(buffer)).reverse())

  applyTo: (buffer) ->
    patch.applyTo(buffer) for patch in @patches

  hasBufferPatches: ->
    find @patches, (patch) -> patch instanceof BufferPatch

  merge: (patch) ->
    if patch instanceof Transaction
      @push(subpatch) for subpatch in patch.patches
      {@groupingExpirationTime} = patch
    else
      @push(patch)

  isOpenForGrouping: ->
    @groupingExpirationTime > Date.now()
