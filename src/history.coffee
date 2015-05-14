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
    for entry, i in @undoStack by -1
      break if i is checkpointIndex
      if @undoStack[i] instanceof Checkpoint
        @undoStack.splice(i, 1)
    true

  applyCheckpointGroupingInterval: (checkpointId, groupingInterval) ->
    return if groupingInterval is 0

    checkpointIndex = @getCheckpointIndex(checkpointId)
    checkpoint = @undoStack[checkpointIndex]
    return unless checkpointIndex?

    now = Date.now()
    groupedCheckpoint = null
    for i in [checkpointIndex - 1..0] by -1
      entry = @undoStack[i]
      if entry instanceof Checkpoint
        if (entry.timestamp + Math.min(entry.groupingInterval, groupingInterval)) >= now
          @undoStack.splice(checkpointIndex, 1)
          groupedCheckpoint = entry
        else
          groupedCheckpoint = checkpoint
        break

    if groupedCheckpoint?
      groupedCheckpoint.timestamp = now
      groupedCheckpoint.groupingInterval = groupingInterval

  pushChange: (change) ->
    @undoStack.push(change)
    @clearRedoStack()

  popUndoStack: (snapshot) ->
    if (checkpointIndex = @getBoundaryCheckpointIndex(@undoStack))?
      @redoStack.push(new Checkpoint(@nextCheckpointId++, snapshot))
      result = @popChanges(@undoStack, @redoStack, checkpointIndex)
      result.changes = (@delegate.invertChange(change) for change in result.changes)
      result
    else
      false

  popRedoStack: (snapshot) ->
    if (checkpointIndex = @getBoundaryCheckpointIndex(@redoStack))?
      @undoStack.push(new Checkpoint(@nextCheckpointId++, snapshot))
      @popChanges(@redoStack, @undoStack, checkpointIndex)
    else
      false

  truncateUndoStack: (checkpointId) ->
    if (checkpointIndex = @getCheckpointIndex(checkpointId))?
      result = @popChanges(@undoStack, null, checkpointIndex)
      result.changes = (@delegate.invertChange(change) for change in result.changes)
      result
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

  popChanges: (fromStack, toStack, checkpointIndex) ->
    changes = []
    snapshot = fromStack[checkpointIndex].snapshot
    for entry in fromStack.splice(checkpointIndex) by -1
      toStack?.push(entry)
      changes.push(entry) unless entry instanceof Checkpoint
    {changes, snapshot}

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
