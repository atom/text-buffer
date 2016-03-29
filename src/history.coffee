Patch = require 'atom-patch'
MarkerLayer = require './marker-layer'

SerializationVersion = 4

class Checkpoint
  constructor: (@id, @snapshot, @isBoundary) ->
    unless @snapshot?
      global.atom?.assert(false, "Checkpoint created without snapshot")
      @snapshot = {}

class GroupStart
  constructor: (@snapshot) ->

class GroupEnd
  constructor: (@snapshot) ->
    @timestamp = Date.now()
    @groupingInterval = 0

# Manages undo/redo for {TextBuffer}
module.exports =
class History
  @deserialize: (state) ->
    history = new History
    history.deserialize(state)
    history

  constructor: (@maxUndoEntries) ->
    @nextCheckpointId = 0
    @undoStackSize = 0
    @undoStack = []
    @redoStack = []

  createCheckpoint: (snapshot, isBoundary) ->
    checkpoint = new Checkpoint(@nextCheckpointId++, snapshot, isBoundary)
    @undoStack.push(checkpoint)
    @undoStackSize += 1
    checkpoint.id

  groupChangesSinceCheckpoint: (checkpointId, endSnapshot, deleteCheckpoint=false) ->
    withinGroup = false
    checkpointIndex = null
    startSnapshot = null
    patchesSinceCheckpoint = []
    previousStackSize = @undoStack

    for entry, i in @undoStack by -1
      break if checkpointIndex?

      switch entry.constructor
        when GroupEnd
          withinGroup = true
          @undoStackSize -= 1
        when GroupStart
          if withinGroup
            withinGroup = false
            @undoStackSize -= 1
          else
            @undoStackSize = previousStackSize
            return false
        when Checkpoint
          if entry.id is checkpointId
            checkpointIndex = i
            startSnapshot = entry.snapshot
          else if entry.isBoundary
            @undoStackSize = previousStackSize
            return false
        else
          @undoStackSize -= entry.getChanges().length
          patchesSinceCheckpoint.unshift(entry)

    if checkpointIndex?
      composedPatches = Patch.compose(patchesSinceCheckpoint)
      if patchesSinceCheckpoint.length > 0
        @undoStack.splice(checkpointIndex + 1)
        @undoStack.push(new GroupStart(startSnapshot))
        @undoStack.push(composedPatches)
        @undoStack.push(new GroupEnd(endSnapshot))
        @undoStackSize += composedPatches.getChanges().length + 2
      if deleteCheckpoint
        @undoStack.splice(checkpointIndex, 1)
        @undoStackSize -= 1
      composedPatches
    else
      false

  applyGroupingInterval: (groupingInterval) ->
    topEntry = @undoStack[@undoStack.length - 1]
    if topEntry instanceof GroupEnd
      topEntry.groupingInterval = groupingInterval
    else
      return

    return if groupingInterval is 0

    for entry, i in @undoStack by -1
      if entry instanceof GroupStart
        previousEntry = @undoStack[i - 1]
        if previousEntry instanceof GroupEnd
          if (topEntry.timestamp - previousEntry.timestamp < Math.min(previousEntry.groupingInterval, groupingInterval))
            previousPatch = @undoStack[i - 2]
            currentPatch = @undoStack[i + 1]
            @undoStack.splice(i - 2, 4, Patch.compose([previousPatch, currentPatch]))
        return

    throw new Error("Didn't find matching group-start entry")

  pushChange: (change) ->
    @undoStack.push(Patch.hunk(change))
    @clearRedoStack()
    @undoStackSize += 1

    if @undoStackSize > @maxUndoEntries
      spliceIndex = null
      withinGroup = false
      for entry, i in @undoStack
        break if spliceIndex?
        switch entry.constructor
          when GroupStart
            if withinGroup
              throw new Error("Invalid undo stack state")
            else
              withinGroup = true
              @undoStackSize -= 1
          when GroupEnd
            if withinGroup
              spliceIndex = i
              @undoStackSize -= 1
            else
              throw new Error("Invalid undo stack state")
          when Patch
            @undoStackSize -= entry.getChanges().length
            unless withinGroup
              spliceIndex = i

      @undoStack.splice(0, spliceIndex + 1) if spliceIndex?

  popUndoStack: ->
    snapshotBelow = null
    spliceIndex = null
    withinGroup = false
    patch = null
    previousStackSize = @undoStackSize

    for entry, i in @undoStack by -1
      break if spliceIndex?

      switch entry.constructor
        when GroupStart
          if withinGroup
            snapshotBelow = entry.snapshot
            spliceIndex = i
            @undoStackSize -= 1
          else
            @undoStackSize = previousStackSize
            return false
        when GroupEnd
          if withinGroup
            throw new Error("Invalid undo stack state")
          else
            withinGroup = true
            @undoStackSize -= 1
        when Checkpoint
          if entry.isBoundary
            @undoStackSize = previousStackSize
            return false
          else
            @undoStackSize -= 1
        else
          patch = Patch.invert(entry)
          @undoStackSize -= patch.getChanges().length
          unless withinGroup
            spliceIndex = i

    if spliceIndex?
      @redoStack.push(@undoStack.splice(spliceIndex).reverse()...)
      {
        snapshot: snapshotBelow
        patch: patch
      }
    else
      false

  popRedoStack: ->
    snapshotBelow = null
    spliceIndex = null
    withinGroup = false
    patch = null
    previousStackSize = @undoStackSize

    for entry, i in @redoStack by -1
      break if spliceIndex?

      switch entry.constructor
        when GroupEnd
          if withinGroup
            snapshotBelow = entry.snapshot
            spliceIndex = i
            @undoStackSize += 1
          else
            @undoStackSize = previousStackSize
            return false
        when GroupStart
          if withinGroup
            throw new Error("Invalid redo stack state")
          else
            @undoStackSize += 1
            withinGroup = true
        when Checkpoint
          if entry.isBoundary
            throw new Error("Invalid redo stack state")
          else
            @undoStackSize += 1
        else
          patch = entry
          @undoStackSize += patch.getChanges().length
          unless withinGroup
            spliceIndex = i

    while @redoStack[spliceIndex - 1] instanceof Checkpoint
      spliceIndex--

    if spliceIndex?
      @undoStack.push(@redoStack.splice(spliceIndex).reverse()...)
      {
        snapshot: snapshotBelow
        patch: patch
      }
    else
      false

  truncateUndoStack: (checkpointId) ->
    snapshotBelow = null
    spliceIndex = null
    withinGroup = false
    patchesSinceCheckpoint = []
    previousStackSize = @undoStackSize

    for entry, i in @undoStack by -1
      break if spliceIndex?

      switch entry.constructor
        when GroupStart
          if withinGroup
            withinGroup = false
            @undoStackSize -= 1
          else
            @undoStackSize = previousStackSize
            return false
        when GroupEnd
          if withinGroup
            throw new Error("Invalid undo stack state")
          else
            withinGroup = true
            @undoStackSize -= 1
        when Checkpoint
          if entry.id is checkpointId
            spliceIndex = i
            snapshotBelow = entry.snapshot
            @undoStackSize -= 1
          else if entry.isBoundary
            @undoStackSize = previousStackSize
            return false
        else
          patch = Patch.invert(entry)
          patchesSinceCheckpoint.push(patch)
          @undoStackSize -= patch.getChanges().length

    if spliceIndex?
      @undoStack.splice(spliceIndex)
      {
        snapshot: snapshotBelow
        patch: Patch.compose(patchesSinceCheckpoint)
      }
    else
      false

  clearUndoStack: ->
    @undoStack.length = 0

  clearRedoStack: ->
    @redoStack.length = 0

  toString: ->
    output = ''
    for entry in @undoStack
      switch entry.constructor
        when Checkpoint
          output += "Checkpoint, "
        when GroupStart
          output += "GroupStart, "
        when GroupEnd
          output += "GroupEnd, "
        when Patch
          output += "Patch, "
        else
          output += "Unknown {#{JSON.stringify(entry)}}, "
    '[' + output.slice(0, -2) + ']'

  serialize: (options) ->
    version: SerializationVersion
    nextCheckpointId: @nextCheckpointId
    undoStack: @serializeStack(@undoStack, options)
    redoStack: @serializeStack(@redoStack, options)

  deserialize: (state) ->
    return unless state.version is SerializationVersion
    @nextCheckpointId = state.nextCheckpointId
    @maxUndoEntries = state.maxUndoEntries
    @undoStack = @deserializeStack(state.undoStack)
    @redoStack = @deserializeStack(state.redoStack)

  ###
  Section: Private
  ###

  getCheckpointIndex: (checkpointId) ->
    for entry, i in @undoStack by -1
      if entry instanceof Checkpoint and entry.id is checkpointId
        return i
    return null

  serializeStack: (stack, options) ->
    for entry in stack
      switch entry.constructor
        when Checkpoint
          {
            type: 'checkpoint'
            id: entry.id
            snapshot: @serializeSnapshot(entry.snapshot, options)
            isBoundary: entry.isBoundary
          }
        when GroupStart
          {
            type: 'group-start'
            snapshot: @serializeSnapshot(entry.snapshot, options)
          }
        when GroupEnd
          {
            type: 'group-end'
            snapshot: @serializeSnapshot(entry.snapshot, options)
          }
        else
          {
            type: 'patch'
            content: entry.serialize()
          }

  deserializeStack: (stack) ->
    for entry in stack
      switch entry.type
        when 'checkpoint'
          new Checkpoint(
            entry.id
            MarkerLayer.deserializeSnapshot(entry.snapshot)
            entry.isBoundary
          )
        when 'group-start'
          new GroupStart(
            MarkerLayer.deserializeSnapshot(entry.snapshot)
          )
        when 'group-end'
          new GroupEnd(
            MarkerLayer.deserializeSnapshot(entry.snapshot)
          )
        when 'patch'
          Patch.deserialize(entry.content)

  serializeSnapshot: (snapshot, options) ->
    return unless options.markerLayers

    MarkerLayer.serializeSnapshot(snapshot)
