{find} = require 'underscore-plus'
Serializable = require 'serializable'
BufferPatch = require './buffer-patch'
MarkerPatch = require './marker-patch'
Marker = require './marker'

# Contains several patches that we want to undo/redo as a batch.
module.exports =
class Transaction extends Serializable
  @registerDeserializers(BufferPatch, MarkerPatch)

  constructor: (@patches, groupingInterval=0, @oldMarkersSnapshot, @newMarkersSnapshot) ->
    @groupingExpirationTime = Date.now() + groupingInterval

  serializeParams: ->
    patches: @patches.map (patch) -> patch.serialize()
    oldMarkersSnapshot: (Marker.serializeSnapshot(@oldMarkersSnapshot) if @oldMarkersSnapshot?)
    newMarkersSnapshot: (Marker.serializeSnapshot(@newMarkersSnapshot) if @newMarkersSnapshot?)

  deserializeParams: (params) ->
    params.patches = params.patches.map (patchState) => @constructor.deserialize(patchState)
    params.oldMarkersSnapshot = Marker.deserializeSnapshot(params.oldMarkersSnapshot)
    params.newMarkersSnapshot = Marker.deserializeSnapshot(params.newMarkersSnapshot)
    params

  push: (patch) ->
    @patches.push(patch)

  invert: (buffer) ->
    newMarkersSnapshot = @oldMarkersSnapshot
    oldMarkersSnapshot = buffer.markers.buildSnapshot()
    new @constructor(@patches.map((patch) -> patch.invert(buffer)).reverse(), 0, oldMarkersSnapshot, newMarkersSnapshot)

  applyTo: (buffer) ->
    patch.applyTo(buffer) for patch in @patches
    buffer.markers.applySnapshot(@newMarkersSnapshot) if @newMarkersSnapshot?

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
