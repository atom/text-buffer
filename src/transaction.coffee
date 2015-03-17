{find} = require 'underscore-plus'
Serializable = require 'serializable'
BufferPatch = require './buffer-patch'

# Contains several patches that we want to undo/redo as a batch.
module.exports =
class Transaction extends Serializable
  @registerDeserializers(BufferPatch)

  constructor: (@patches, @oldMarkersSnapshot, @newMarkersSnapshot, groupingInterval=0) ->
    @groupingExpirationTime = Date.now() + groupingInterval

  serializeParams: ->
    patches: @patches.map (patch) -> patch.serialize()
    oldMarkersSnapshot: @oldMarkersSnapshot
    newMarkersSnapshot: @newMarkersSnapshot

  deserializeParams: (params) ->
    params.patches = params.patches.map (patchState) => @constructor.deserialize(patchState)
    params

  push: (patch) ->
    @patches.push(patch)

  invert: (buffer) ->
    patches = @patches.map((patch) -> patch.invert(buffer)).reverse()
    oldMarkersSnapshot = buffer.markers.buildSnapshot()
    newMarkersSnapshot = @oldMarkersSnapshot
    new @constructor(patches, oldMarkersSnapshot, newMarkersSnapshot)

  applyTo: (buffer) ->
    patch.applyTo(buffer) for patch in @patches
    buffer.markers.applySnapshot(@newMarkersSnapshot) if @newMarkersSnapshot?

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
