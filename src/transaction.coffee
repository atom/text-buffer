{find} = require 'underscore-plus'
Serializable = require 'serializable'
BufferPatch = require './buffer-patch'
Marker = require './marker'

# Contains several patches that we want to undo/redo as a batch.
module.exports =
class Transaction extends Serializable
  @registerDeserializers(BufferPatch)

  newMarkersSnapshot: null

  constructor: (@patches, groupingInterval=0, @oldMarkersSnapshot, @newMarkersSnapshot) ->
    @groupingExpirationTime = Date.now() + groupingInterval

  serializeParams: ->
    patches: @patches.map (patch) -> patch.serialize()
    oldMarkersSnapshot: (Marker.serializeSnapshot(@oldMarkersSnapshot) if @oldMarkersSnapshot?)
    newMarkersSnapshot: (Marker.serializeSnapshot(@newMarkersSnapshot) if @newMarkersSnapshot?)

  deserializeParams: (params) ->
    params.patches = params.patches.map (patchState) => @constructor.deserialize(patchState)
    params.oldMarkersSnapshot = Marker.deserializeSnapshot(params.oldMarkersSnapshot) if params.oldMarkersSnapshot?
    params.newMarkersSnapshot = Marker.deserializeSnapshot(params.newMarkersSnapshot) if params.newMarkersSnapshot?
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
