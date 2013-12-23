module.exports =
class History
  constructor: (@textBuffer) ->
    @undoStack = []
    @redoStack = []

  recordNewPatch: (patch) ->
    @undoStack.push(patch)
    @redoStack.length = 0

  undo: ->
    if patch = @undoStack.pop()
      inverse = @textBuffer.invertPatch(patch)
      @redoStack.push(inverse)
      @textBuffer.applyPatch(inverse)

  redo: ->
    if patch = @redoStack.pop()
      inverse = @textBuffer.invertPatch(patch)
      @undoStack.push(inverse)
      @textBuffer.applyPatch(inverse)
