SerializationVersion = 2

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
  @deserialize: (delegate, state) ->
    history = new History(delegate)
    history.deserialize(state)
    history

  constructor: (@delegate) ->
    @nextCheckpointId = 0
    @undoStack = []
    @redoStack = []

  createCheckpoint: (snapshot, isBoundary) ->
    checkpoint = new Checkpoint(@nextCheckpointId++, snapshot, isBoundary)
    @undoStack.push(checkpoint)
    checkpoint.id

  groupChangesSinceCheckpoint: (checkpointId, endSnapshot, deleteCheckpoint=false) ->
    withinGroup = false
    checkpointIndex = null
    startSnapshot = null
    changesSinceCheckpoint = []

    for entry, i in @undoStack by -1
      break if checkpointIndex?

      switch entry.constructor
        when GroupEnd
          withinGroup = true
        when GroupStart
          if withinGroup
            withinGroup = false
          else
            return false
        when Checkpoint
          if entry.id is checkpointId
            checkpointIndex = i
            startSnapshot = entry.snapshot
          else if entry.isBoundary
            return false
        else
          changesSinceCheckpoint.unshift(entry)

    if checkpointIndex?
      if changesSinceCheckpoint.length > 0
        @undoStack.splice(checkpointIndex + 1)
        @undoStack.push(new GroupStart(startSnapshot))
        @undoStack.push(changesSinceCheckpoint...)
        @undoStack.push(new GroupEnd(endSnapshot))
      if deleteCheckpoint
        @undoStack.splice(checkpointIndex, 1)
      true
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
          if (topEntry.timestamp - previousEntry.timestamp < Math.min(previousEntry.groupingInterval, groupingInterval)) or (previousEntry.groupingInterval is Infinity)
            @undoStack.splice(i - 1, 2)
        return

    throw new Error("Didn't find matching group-start entry")

  pushChange: (change) ->
    @undoStack.push(change)
    @clearRedoStack()

  popUndoStack: ->
    snapshotBelow = null
    spliceIndex = null
    withinGroup = false
    invertedChanges = []

    for entry, i in @undoStack by -1
      break if spliceIndex?

      switch entry.constructor
        when GroupStart
          if withinGroup
            snapshotBelow = entry.snapshot
            spliceIndex = i
          else
            return false
        when GroupEnd
          if withinGroup
            throw new Error("Invalid undo stack state")
          else
            withinGroup = true
        when Checkpoint
          if entry.isBoundary
            return false
        else
          invertedChanges.push(@delegate.invertChange(entry))
          unless withinGroup
            spliceIndex = i

    if spliceIndex?
      @redoStack.push(@undoStack.splice(spliceIndex).reverse()...)
      {
        snapshot: snapshotBelow
        changes: invertedChanges
      }
    else
      false

  popRedoStack: ->
    snapshotBelow = null
    spliceIndex = null
    withinGroup = false
    changes = []

    for entry, i in @redoStack by -1
      break if spliceIndex?

      switch entry.constructor
        when GroupEnd
          if withinGroup
            snapshotBelow = entry.snapshot
            spliceIndex = i
          else
            return false
        when GroupStart
          if withinGroup
            throw new Error("Invalid redo stack state")
          else
            withinGroup = true
        when Checkpoint
          if entry.isBoundary
            throw new Error("Invalid redo stack state")
        else
          changes.push(entry)
          unless withinGroup
            spliceIndex = i

    while @redoStack[spliceIndex - 1] instanceof Checkpoint
      spliceIndex--

    if spliceIndex?
      @undoStack.push(@redoStack.splice(spliceIndex).reverse()...)
      {
        snapshot: snapshotBelow
        changes: changes
      }
    else
      false

  truncateUndoStack: (checkpointId) ->
    snapshotBelow = null
    spliceIndex = null
    withinGroup = false
    invertedChanges = []

    for entry, i in @undoStack by -1
      break if spliceIndex?

      switch entry.constructor
        when GroupStart
          if withinGroup
            withinGroup = false
          else
            return false
        when GroupEnd
          if withinGroup
            throw new Error("Invalid undo stack state")
          else
            withinGroup = true
        when Checkpoint
          if entry.id is checkpointId
            spliceIndex = i
            snapshotBelow = entry.snapshot
          else if entry.isBoundary
            return false
        else
          invertedChanges.push(@delegate.invertChange(entry))

    if spliceIndex?
      @undoStack.splice(spliceIndex)
      {
        snapshot: snapshotBelow
        changes: invertedChanges
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

  serializeStack: (stack) ->
    for entry in stack
      switch entry.constructor
        when Checkpoint
          {
            type: 'checkpoint'
            id: entry.id
            snapshot: @delegate.serializeSnapshot(entry.snapshot)
            isBoundary: entry.isBoundary
          }
        when GroupStart
          {
            type: 'group-start'
            snapshot: @delegate.serializeSnapshot(entry.snapshot)
          }
        when GroupEnd
          {
            type: 'group-end'
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
            entry.isBoundary
          )
        when 'group-start'
          new GroupStart(
            @delegate.deserializeSnapshot(entry.snapshot)
          )
        when 'group-end'
          new GroupEnd(
            @delegate.deserializeSnapshot(entry.snapshot)
          )
        when 'change'
          @delegate.deserializeChange(entry.content)
