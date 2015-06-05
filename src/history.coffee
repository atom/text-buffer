_ = require 'underscore-plus'

SerializationVersion = 2

class Checkpoint
  constructor: (@id, @snapshot) ->

# Manages undo/redo for {TextBuffer}
module.exports =
class History
  @deserialize: (delegate, state) ->
    history = new History(delegate)
    history.deserialize(state)
    history

  constructor: (@delegate) ->
    @nextCheckpointId = 0
    @undoStack = []
    @redoStack = []

  createCheckpoint: (snapshot) ->
    checkpoint = new Checkpoint(@nextCheckpointId++, snapshot)
    @undoStack.push(checkpoint)
    checkpoint.id

  groupChangesSinceCheckpoint: (checkpointId) ->
    checkpointIndex = @getCheckpointIndex(checkpointId)
    return false unless checkpointIndex?
    for i in [(@undoStack.length - 2)...checkpointIndex] by -1
      @undoStack.splice(i, 1) if @undoStack[i] instanceof Checkpoint
    true

  applyCheckpointGroupingInterval: (checkpointId, now, groupingInterval) ->
    return if groupingInterval is 0

    checkpointIndex = @getCheckpointIndex(checkpointId)
    return unless checkpointIndex?

    i = lastCheckpointIndex = checkpointIndex
    while entry = @undoStack[--i]
      if entry instanceof Checkpoint
        if (entry.timestamp + Math.min(entry.groupingInterval, groupingInterval)) <= now
          break
        @undoStack.splice(lastCheckpointIndex, 1)
        lastCheckpointIndex = i

    @undoStack[lastCheckpointIndex].timestamp = now
    @undoStack[lastCheckpointIndex].groupingInterval = groupingInterval

  setCheckpointGroupingInterval: (checkpointId, timestamp, groupingInterval) ->
    checkpointIndex = @getCheckpointIndex(checkpointId)
    checkpoint = @undoStack[checkpointIndex]
    checkpoint.timestamp = timestamp
    checkpoint.groupingInterval = groupingInterval

  pushChange: (change) ->
    @undoStack.push(change)
    @clearRedoStack()

  popUndoStack: (currentSnapshot) ->
    if (checkpointIndex = @getBoundaryCheckpointIndex(@undoStack))?
      pop = @popChanges(@undoStack, @redoStack, checkpointIndex)
      _.defaults(pop.snapshotAbove, currentSnapshot)
      {
        snapshot: pop.snapshotBelow
        changes: (@delegate.invertChange(change) for change in pop.changes)
      }
    else
      false

  popRedoStack: (currentSnapshot) ->
    if (checkpointIndex = @getBoundaryCheckpointIndex(@redoStack))?
      checkpointIndex-- while @redoStack[checkpointIndex - 1] instanceof Checkpoint
      checkpointIndex++ if @redoStack[checkpointIndex - 1]?
      pop = @popChanges(@redoStack, @undoStack, checkpointIndex, true)
      _.defaults(pop.snapshotAbove, currentSnapshot)
      {
        snapshot: pop.snapshotBelow
        changes: pop.changes
      }
    else
      false

  truncateUndoStack: (checkpointId) ->
    if (checkpointIndex = @getCheckpointIndex(checkpointId))?
      pop = @popChanges(@undoStack, null, checkpointIndex)
      {
        snapshot: pop.snapshotBelow
        changes: (@delegate.invertChange(change) for change in pop.changes)
      }
    else
      false

  clearUndoStack: ->
    @undoStack.length = 0

  clearRedoStack: ->
    @redoStack.length = 0

  serialize: ->
    version: SerializationVersion
    nextCheckpointId: @nextCheckpointId
    undoStack: @serializeStack(@undoStack)
    redoStack: @serializeStack(@redoStack)

  deserialize: (state) ->
    return unless state.version is SerializationVersion
    @nextCheckpointId = state.nextCheckpointId
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

  getBoundaryCheckpointIndex: (stack) ->
    hasSeenChanges = false
    for entry, i in stack by -1
      if entry instanceof Checkpoint
        return i if hasSeenChanges
      else
        hasSeenChanges = true
    null

  popChanges: (fromStack, toStack, checkpointIndex, lookBack) ->
    changes = []
    snapshotAbove = null
    snapshotBelow = fromStack[checkpointIndex].snapshot
    splicedEntries = fromStack.splice(checkpointIndex)
    for entry in splicedEntries by -1
      toStack?.push(entry)
      if entry instanceof Checkpoint
        snapshotAbove = entry.snapshot if changes.length is 0
      else
        changes.push(entry)
    {changes, snapshotAbove, snapshotBelow}

  serializeStack: (stack) ->
    for entry in stack
      if entry instanceof Checkpoint
        {
          type: 'checkpoint'
          id: entry.id
          snapshot: @delegate.serializeSnapshot(entry.snapshot)
        }
      else
        {
          type: 'change'
          content: @delegate.serializeChange(entry)
        }

  deserializeStack: (stack) ->
    for entry in stack
      switch entry.type
        when 'checkpoint'
          new Checkpoint(
            entry.id
            @delegate.deserializeSnapshot(entry.snapshot)
          )
        when 'change'
          @delegate.deserializeChange(entry.content)
