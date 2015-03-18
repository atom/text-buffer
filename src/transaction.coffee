{find} = require 'underscore-plus'
Serializable = require 'serializable'
BufferPatch = require './buffer-patch'

# Contains several patches that we want to undo/redo as a batch.
module.exports =
class Transaction extends Serializable
  @registerDeserializers(BufferPatch)

  oldMarkersSnapshot: null

  constructor: (@patches, groupingInterval=0, @newMarkersSnapshot, @oldMarkersSnapshot) ->
    @groupingExpirationTime = Date.now() + groupingInterval

  serializeParams: ->
    patches: @patches.map (patch) -> patch.serialize()
    newMarkersSnapshot: @newMarkersSnapshot
    oldMarkersSnapshot: @oldMarkersSnapshot

  deserializeParams: (params) ->
    params.patches = params.patches.map (patchState) => @constructor.deserialize(patchState)
    params

  push: (patch) ->
    @patches.push(patch)

  invert: (buffer) ->
    invertedPatches = @patches.map((patch) -> patch.invert(buffer)).reverse()
    newMarkersSnapshot = @oldMarkersSnapshot
    oldMarkersSnapshot = buffer.markers.buildSnapshot(newMarkersSnapshot)
    new @constructor(invertedPatches, 0, newMarkersSnapshot, oldMarkersSnapshot)

  applyTo: (buffer) ->
    patch.applyTo(buffer) for patch in @patches
    buffer.markers.restoreSnapshot(@newMarkersSnapshot) if @newMarkersSnapshot?

  isEmpty: ->
    @patches.length is 0

  merge: (patch) ->
    if patch instanceof Transaction
      @push(subpatch) for subpatch in patch.patches
      {@groupingExpirationTime} = patch
    else
      @push(patch)

  isOpenForGrouping: ->
    @groupingExpirationTime > Date.now()
