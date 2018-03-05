fs = require 'fs-plus'
{join} = require 'path'
temp = require 'temp'
{File} = require 'pathwatcher'
Random = require 'random-seed'
Point = require '../src/point'
Range = require '../src/range'
DisplayLayer = require '../src/display-layer'
DefaultHistoryProvider = require '../src/default-history-provider'
TextBuffer = require '../src/text-buffer'
SampleText = fs.readFileSync(join(__dirname, 'fixtures', 'sample.js'), 'utf8')
{buildRandomLines, getRandomBufferRange} = require './helpers/random'
NullLanguageMode = require '../src/null-language-mode'

describe "TextBuffer", ->
  buffer = null

  beforeEach ->
    temp.track()
    jasmine.addCustomEqualityTester(require("underscore-plus").isEqual)
    # When running specs in Atom, setTimeout is spied on by default.
    jasmine.useRealClock?()

  afterEach ->
    buffer?.destroy()
    buffer = null

  describe "construction", ->
    it "can be constructed empty", ->
      buffer = new TextBuffer
      expect(buffer.getLineCount()).toBe 1
      expect(buffer.getText()).toBe ''
      expect(buffer.lineForRow(0)).toBe ''
      expect(buffer.lineEndingForRow(0)).toBe ''

    it "can be constructed with initial text containing no trailing newline", ->
      text = "hello\nworld\r\nhow are you doing?\r\nlast"
      buffer = new TextBuffer(text)
      expect(buffer.getLineCount()).toBe 4
      expect(buffer.getText()).toBe text
      expect(buffer.lineForRow(0)).toBe 'hello'
      expect(buffer.lineEndingForRow(0)).toBe '\n'
      expect(buffer.lineForRow(1)).toBe 'world'
      expect(buffer.lineEndingForRow(1)).toBe '\r\n'
      expect(buffer.lineForRow(2)).toBe 'how are you doing?'
      expect(buffer.lineEndingForRow(2)).toBe '\r\n'
      expect(buffer.lineForRow(3)).toBe 'last'
      expect(buffer.lineEndingForRow(3)).toBe ''

    it "can be constructed with initial text containing a trailing newline", ->
      text = "first\n"
      buffer = new TextBuffer(text)
      expect(buffer.getLineCount()).toBe 2
      expect(buffer.getText()).toBe text
      expect(buffer.lineForRow(0)).toBe 'first'
      expect(buffer.lineEndingForRow(0)).toBe '\n'
      expect(buffer.lineForRow(1)).toBe ''
      expect(buffer.lineEndingForRow(1)).toBe ''

    it "automatically assigns a unique identifier to new buffers", ->
      bufferIds = [0..16].map(-> new TextBuffer().getId())
      uniqueBufferIds = new Set(bufferIds)

      expect(uniqueBufferIds.size).toBe(bufferIds.length)

  describe "::destroy()", ->
    it "clears the buffer's state", ->
      filePath = temp.openSync('atom').path
      buffer = new TextBuffer()
      buffer.setPath(filePath)
      buffer.append("a")
      buffer.append("b")
      buffer.destroy()

      expect(buffer.getText()).toBe('')
      buffer.undo()
      expect(buffer.getText()).toBe('')
      expect(-> buffer.save()).toThrowError(/Can't save destroyed buffer/)

  describe "::setTextInRange(range, text)", ->
    beforeEach ->
      buffer = new TextBuffer("hello\nworld\r\nhow are you doing?")

    it "can replace text on a single line with a standard newline", ->
      buffer.setTextInRange([[0, 2], [0, 4]], "y y")
      expect(buffer.getText()).toEqual "hey yo\nworld\r\nhow are you doing?"

    it "can replace text on a single line with a carriage-return/newline", ->
      buffer.setTextInRange([[1, 3], [1, 5]], "ms")
      expect(buffer.getText()).toEqual "hello\nworms\r\nhow are you doing?"

    it "can replace text in a region spanning multiple lines, ending on the last line", ->
      buffer.setTextInRange([[0, 2], [2, 3]], "y there\r\ncat\nwhat", normalizeLineEndings: false)
      expect(buffer.getText()).toEqual "hey there\r\ncat\nwhat are you doing?"

    it "can replace text in a region spanning multiple lines, ending with a carriage-return/newline", ->
      buffer.setTextInRange([[0, 2], [1, 3]], "y\nyou're o", normalizeLineEndings: false)
      expect(buffer.getText()).toEqual "hey\nyou're old\r\nhow are you doing?"

    describe "after a change", ->
      it "notifies, in order: the language mode, display layers, and display layer ::onDidChange observers with the relevant details", ->
        buffer = new TextBuffer("hello\nworld\r\nhow are you doing?")

        events = []
        languageMode = {
          bufferDidChange: (e) -> events.push({source: 'language-mode', event: e}),
          onDidChangeHighlighting: -> {dispose: ->}
        }
        displayLayer1 = buffer.addDisplayLayer()
        displayLayer2 = buffer.addDisplayLayer()
        spyOn(displayLayer1, 'bufferDidChange').and.callFake (e) ->
          events.push({source: 'display-layer-1', event: e})
          DisplayLayer.prototype.bufferDidChange.call(displayLayer1, e)
        spyOn(displayLayer2, 'bufferDidChange').and.callFake (e) ->
          events.push({source: 'display-layer-2', event: e})
          DisplayLayer.prototype.bufferDidChange.call(displayLayer2, e)
        buffer.setLanguageMode(languageMode)
        buffer.onDidChange (e) -> events.push({source: 'buffer', event: JSON.parse(JSON.stringify(e))})
        displayLayer1.onDidChange (e) -> events.push({source: 'display-layer-event', event: e})

        buffer.transact ->
          buffer.setTextInRange([[0, 2], [2, 3]], "y there\r\ncat\nwhat", normalizeLineEndings: false)
          buffer.setTextInRange([[1, 1], [1, 2]], "abc", normalizeLineEndings: false)

        changeEvent1 = {
          oldRange: [[0, 2], [2, 3]], newRange: [[0, 2], [2, 4]]
          oldText: "llo\nworld\r\nhow", newText: "y there\r\ncat\nwhat",
        }
        changeEvent2 = {
          oldRange: [[1, 1], [1, 2]], newRange: [[1, 1], [1, 4]]
          oldText: "a", newText: "abc",
        }
        expect(events).toEqual [
          {source: 'language-mode', event: changeEvent1},
          {source: 'display-layer-1', event: changeEvent1},
          {source: 'display-layer-2', event: changeEvent1},

          {source: 'language-mode', event: changeEvent2},
          {source: 'display-layer-1', event: changeEvent2},
          {source: 'display-layer-2', event: changeEvent2},

          {
            source: 'buffer',
            event: {
              oldRange: Range(Point(0, 2), Point(2, 3)),
              newRange: Range(Point(0, 2), Point(2, 4)),
              changes: [
                {
                  oldRange: Range(Point(0, 2), Point(2, 3)),
                  newRange: Range(Point(0, 2), Point(2, 4)),
                  oldText: "llo\nworld\r\nhow",
                  newText: "y there\r\ncabct\nwhat"
                }
              ]
            }
          },
          {
            source: 'display-layer-event',
            event: [{
              oldRange: Range(Point(0, 0), Point(3, 0)),
              newRange: Range(Point(0, 0), Point(3, 0))
            }]
          }
        ]

    it "returns the newRange of the change", ->
      expect(buffer.setTextInRange([[0, 2], [2, 3]], "y there\r\ncat\nwhat"), normalizeLineEndings: false).toEqual [[0, 2], [2, 4]]

    it "clips the given range", ->
      buffer.setTextInRange([[-1, -1], [0, 1]], "y")
      buffer.setTextInRange([[0, 10], [0, 100]], "w")
      expect(buffer.lineForRow(0)).toBe "yellow"

    it "preserves the line endings of existing lines", ->
      buffer.setTextInRange([[0, 1], [0, 2]], 'o')
      expect(buffer.lineEndingForRow(0)).toBe '\n'
      buffer.setTextInRange([[1, 1], [1, 3]], 'i')
      expect(buffer.lineEndingForRow(1)).toBe '\r\n'

    it "freezes change event ranges", ->
      changedOldRange = null
      changedNewRange = null
      buffer.onDidChange ({oldRange, newRange}) ->
        oldRange.start = Point(0, 3)
        oldRange.start.row = 1
        newRange.start = Point(4, 4)
        newRange.end.row = 2
        changedOldRange = oldRange
        changedNewRange = newRange

      buffer.setTextInRange(Range(Point(0, 2), Point(0, 4)), "y y")

      expect(changedOldRange).toEqual([[0, 2], [0, 4]])
      expect(changedNewRange).toEqual([[0, 2], [0, 5]])

    describe "when the undo option is 'skip'", ->
      it "replaces the contents of the buffer with the given text", ->
        buffer.setTextInRange([[0, 0], [0, 1]], "y")
        buffer.setTextInRange([[0, 10], [0, 100]], "w", {undo: 'skip'})
        expect(buffer.lineForRow(0)).toBe "yellow"

        expect(buffer.undo()).toBe true
        expect(buffer.lineForRow(0)).toBe "hello"

      it "still emits marker change events (regression)", ->
        markerLayer = buffer.addMarkerLayer()
        marker = markerLayer.markRange([[0, 0], [0, 3]])

        markerLayerUpdateEventsCount = 0
        markerChangeEvents = []
        markerLayer.onDidUpdate -> markerLayerUpdateEventsCount++
        marker.onDidChange (event) -> markerChangeEvents.push(event)

        buffer.setTextInRange([[0, 0], [0, 1]], '', {undo: 'skip'})
        expect(markerLayerUpdateEventsCount).toBe(1)
        expect(markerChangeEvents).toEqual([{
          wasValid: true, isValid: true,
          hadTail: true, hasTail: true,
          oldProperties: {}, newProperties: {},
          oldHeadPosition: Point(0, 3), newHeadPosition: Point(0, 2),
          oldTailPosition: Point(0, 0), newTailPosition: Point(0, 0),
          textChanged: true
        }])
        markerChangeEvents.length = 0

        buffer.transact ->
          buffer.setTextInRange([[0, 0], [0, 1]], '', {undo: 'skip'})
        expect(markerLayerUpdateEventsCount).toBe(2)
        expect(markerChangeEvents).toEqual([{
          wasValid: true, isValid: true,
          hadTail: true, hasTail: true,
          oldProperties: {}, newProperties: {},
          oldHeadPosition: Point(0, 2), newHeadPosition: Point(0, 1),
          oldTailPosition: Point(0, 0), newTailPosition: Point(0, 0),
          textChanged: true
        }])

      it "still emits text change events (regression)", (done) ->
        didChangeEvents = []
        buffer.onDidChange (event) -> didChangeEvents.push(event)

        buffer.onDidStopChanging ({changes}) ->
          assertChangesEqual(changes, [{
            oldRange: [[0, 0], [0, 1]],
            newRange: [[0, 0], [0, 1]],
            oldText: 'h',
            newText: 'z'
          }])
          done()

        buffer.setTextInRange([[0, 0], [0, 1]], 'y', {undo: 'skip'})
        expect(didChangeEvents.length).toBe(1)
        assertChangesEqual(didChangeEvents[0].changes, [{
          oldRange: [[0, 0], [0, 1]],
          newRange: [[0, 0], [0, 1]],
          oldText: 'h',
          newText: 'y'
        }])

        buffer.transact -> buffer.setTextInRange([[0, 0], [0, 1]], 'z', {undo: 'skip'})
        expect(didChangeEvents.length).toBe(2)
        assertChangesEqual(didChangeEvents[1].changes, [{
          oldRange: [[0, 0], [0, 1]],
          newRange: [[0, 0], [0, 1]],
          oldText: 'y',
          newText: 'z'
        }])

    describe "when the normalizeLineEndings argument is true (the default)", ->
      describe "when the range's start row has a line ending", ->
        it "normalizes inserted line endings to match the line ending of the range's start row", ->
          changeEvents = []
          buffer.onDidChange (e) -> changeEvents.push(e)

          expect(buffer.lineEndingForRow(0)).toBe '\n'
          buffer.setTextInRange([[0, 2], [0, 5]], "y\r\nthere\r\ncrazy")
          expect(buffer.lineEndingForRow(0)).toBe '\n'
          expect(buffer.lineEndingForRow(1)).toBe '\n'
          expect(buffer.lineEndingForRow(2)).toBe '\n'
          expect(changeEvents[0].newText).toBe "y\nthere\ncrazy"

          expect(buffer.lineEndingForRow(3)).toBe '\r\n'
          buffer.setTextInRange([[3, 3], [4, Infinity]], "ms\ndo you\r\nlike\ndirt")
          expect(buffer.lineEndingForRow(3)).toBe '\r\n'
          expect(buffer.lineEndingForRow(4)).toBe '\r\n'
          expect(buffer.lineEndingForRow(5)).toBe '\r\n'
          expect(buffer.lineEndingForRow(6)).toBe ''
          expect(changeEvents[1].newText).toBe "ms\r\ndo you\r\nlike\r\ndirt"

          buffer.setTextInRange([[5, 1], [5, 3]], '\r')
          expect(changeEvents[2].changes).toEqual([{
            oldRange: [[5, 1], [5, 3]],
            newRange: [[5, 1], [6, 0]],
            oldText: 'ik',
            newText: '\r\n'
          }])

          buffer.undo()
          expect(changeEvents[3].changes).toEqual([{
            oldRange: [[5, 1], [6, 0]],
            newRange: [[5, 1], [5, 3]],
            oldText: '\r\n',
            newText: 'ik'
          }])

          buffer.redo()
          expect(changeEvents[4].changes).toEqual([{
            oldRange: [[5, 1], [5, 3]],
            newRange: [[5, 1], [6, 0]],
            oldText: 'ik',
            newText: '\r\n'
          }])

      describe "when the range's start row has no line ending (because it's the last line of the buffer)", ->
        describe "when the buffer contains no newlines", ->
          it "honors the newlines in the inserted text", ->
            buffer = new TextBuffer("hello")
            buffer.setTextInRange([[0, 2], [0, Infinity]], "hey\r\nthere\nworld")
            expect(buffer.lineEndingForRow(0)).toBe '\r\n'
            expect(buffer.lineEndingForRow(1)).toBe '\n'
            expect(buffer.lineEndingForRow(2)).toBe ''

        describe "when the buffer contains newlines", ->
          it "normalizes inserted line endings to match the line ending of the penultimate row", ->
            expect(buffer.lineEndingForRow(1)).toBe '\r\n'
            buffer.setTextInRange([[2, 0], [2, Infinity]], "what\ndo\r\nyou\nwant?")
            expect(buffer.lineEndingForRow(2)).toBe '\r\n'
            expect(buffer.lineEndingForRow(3)).toBe '\r\n'
            expect(buffer.lineEndingForRow(4)).toBe '\r\n'
            expect(buffer.lineEndingForRow(5)).toBe ''

    describe "when the normalizeLineEndings argument is false", ->
      it "honors the newlines in the inserted text", ->
        buffer.setTextInRange([[1, 0], [1, 5]], "moon\norbiting\r\nhappily\nthere", {normalizeLineEndings: false})
        expect(buffer.lineEndingForRow(1)).toBe '\n'
        expect(buffer.lineEndingForRow(2)).toBe '\r\n'
        expect(buffer.lineEndingForRow(3)).toBe '\n'
        expect(buffer.lineEndingForRow(4)).toBe '\r\n'
        expect(buffer.lineEndingForRow(5)).toBe ''

  describe "::setText(text)", ->
    it "replaces the contents of the buffer with the given text", ->
      buffer = new TextBuffer("hello\nworld\r\nyou are cool")
      buffer.setText("goodnight\r\nmoon\nit's been good")
      expect(buffer.getText()).toBe "goodnight\r\nmoon\nit's been good"
      buffer.undo()
      expect(buffer.getText()).toBe "hello\nworld\r\nyou are cool"

  describe "::insert(position, text, normalizeNewlinesn)", ->
    it "inserts text at the given position", ->
      buffer = new TextBuffer("hello world")
      buffer.insert([0, 5], " there")
      expect(buffer.getText()).toBe "hello there world"

    it "honors the normalizeNewlines option", ->
      buffer = new TextBuffer("hello\nworld")
      buffer.insert([0, 5], "\r\nthere\r\nlittle", normalizeLineEndings: false)
      expect(buffer.getText()).toBe "hello\r\nthere\r\nlittle\nworld"

  describe "::append(text, normalizeNewlines)", ->
    it "appends text to the end of the buffer", ->
      buffer = new TextBuffer("hello world")
      buffer.append(", how are you?")
      expect(buffer.getText()).toBe "hello world, how are you?"

    it "honors the normalizeNewlines option", ->
      buffer = new TextBuffer("hello\nworld")
      buffer.append("\r\nhow\r\nare\nyou?", normalizeLineEndings: false)
      expect(buffer.getText()).toBe "hello\nworld\r\nhow\r\nare\nyou?"

  describe "::delete(range)", ->
    it "deletes text in the given range", ->
      buffer = new TextBuffer("hello world")
      buffer.delete([[0, 5], [0, 11]])
      expect(buffer.getText()).toBe "hello"

  describe "::deleteRows(startRow, endRow)", ->
    beforeEach ->
      buffer = new TextBuffer("first\nsecond\nthird\nlast")

    describe "when the endRow is less than the last row of the buffer", ->
      it "deletes the specified rows", ->
        buffer.deleteRows(1, 2)
        expect(buffer.getText()).toBe "first\nlast"
        buffer.deleteRows(0, 0)
        expect(buffer.getText()).toBe "last"

    describe "when the endRow is the last row of the buffer", ->
      it "deletes the specified rows", ->
        buffer.deleteRows(2, 3)
        expect(buffer.getText()).toBe "first\nsecond"
        buffer.deleteRows(0, 1)
        expect(buffer.getText()).toBe ""

    it "clips the given row range", ->
      buffer.deleteRows(-1, 0)
      expect(buffer.getText()).toBe "second\nthird\nlast"
      buffer.deleteRows(1, 5)
      expect(buffer.getText()).toBe "second"

      buffer.deleteRows(-2, -1)
      expect(buffer.getText()).toBe "second"
      buffer.deleteRows(1, 2)
      expect(buffer.getText()).toBe "second"

    it "handles out of order row ranges", ->
      buffer.deleteRows(2, 1)
      expect(buffer.getText()).toBe "first\nlast"

  describe "::getText()", ->
    it "returns the contents of the buffer as a single string", ->
      buffer = new TextBuffer("hello\nworld\r\nhow are you?")
      expect(buffer.getText()).toBe "hello\nworld\r\nhow are you?"
      buffer.setTextInRange([[1, 0], [1, 5]], "mom")
      expect(buffer.getText()).toBe "hello\nmom\r\nhow are you?"

  describe "::undo() and ::redo()", ->
    beforeEach ->
      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")

    it "undoes and redoes multiple changes", ->
      buffer.setTextInRange([[0, 5], [0, 5]], " there")
      buffer.setTextInRange([[1, 0], [1, 5]], "friend")
      expect(buffer.getText()).toBe "hello there\nfriend\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello there\nworld\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      buffer.redo()
      expect(buffer.getText()).toBe "hello there\nworld\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      buffer.redo()
      buffer.redo()
      expect(buffer.getText()).toBe "hello there\nfriend\r\nhow are you doing?"

      buffer.redo()
      expect(buffer.getText()).toBe "hello there\nfriend\r\nhow are you doing?"

    it "clears the redo stack upon a fresh change", ->
      buffer.setTextInRange([[0, 5], [0, 5]], " there")
      buffer.setTextInRange([[1, 0], [1, 5]], "friend")
      expect(buffer.getText()).toBe "hello there\nfriend\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello there\nworld\r\nhow are you doing?"

      buffer.setTextInRange([[1, 3], [1, 5]], "m")
      expect(buffer.getText()).toBe "hello there\nworm\r\nhow are you doing?"

      buffer.redo()
      expect(buffer.getText()).toBe "hello there\nworm\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello there\nworld\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

    it "does not allow the undo stack to grow without bound", ->
      buffer = new TextBuffer(maxUndoEntries: 12)

      # Each transaction is treated as a single undo entry. We can undo up
      # to 12 of them.
      buffer.setText("")
      buffer.clearUndoStack()
      for i in [0...13]
        buffer.transact ->
          buffer.append(String(i))
          buffer.append("\n")
      expect(buffer.getLineCount()).toBe 14

      undoCount = 0
      undoCount++ while buffer.undo()
      expect(undoCount).toBe 12
      expect(buffer.getText()).toBe '0\n'

  describe "transactions", ->
    now = null

    beforeEach ->
      now = 0
      spyOn(Date, 'now').and.callFake -> now

      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      buffer.setTextInRange([[1, 3], [1, 5]], 'ms')

    describe "::transact(groupingInterval, fn)", ->
      it "groups all operations in the given function in a single transaction", ->
        buffer.transact ->
          buffer.setTextInRange([[0, 2], [0, 5]], "y")
          buffer.transact ->
            buffer.setTextInRange([[2, 13], [2, 14]], "igg")

        expect(buffer.getText()).toBe "hey\nworms\r\nhow are you digging?"
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      it "halts execution of the function if the transaction is aborted", ->
        innerContinued = false
        outerContinued = false

        buffer.transact ->
          buffer.setTextInRange([[0, 2], [0, 5]], "y")
          buffer.transact ->
            buffer.setTextInRange([[2, 13], [2, 14]], "igg")
            buffer.abortTransaction()
            innerContinued = true
          outerContinued = true

        expect(innerContinued).toBe false
        expect(outerContinued).toBe true
        expect(buffer.getText()).toBe "hey\nworms\r\nhow are you doing?"

      it "groups all operations performed within the given function into a single undo/redo operation", ->
        buffer.transact ->
          buffer.setTextInRange([[0, 2], [0, 5]], "y")
          buffer.setTextInRange([[2, 13], [2, 14]], "igg")

        expect(buffer.getText()).toBe "hey\nworms\r\nhow are you digging?"

        # subsequent changes are not included in the transaction
        buffer.setTextInRange([[1, 0], [1, 0]], "little ")
        buffer.undo()
        expect(buffer.getText()).toBe "hey\nworms\r\nhow are you digging?"

        # this should undo all changes in the transaction
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        # previous changes are not included in the transaction
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

        buffer.redo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        # this should redo all changes in the transaction
        buffer.redo()
        expect(buffer.getText()).toBe "hey\nworms\r\nhow are you digging?"

        # this should redo the change following the transaction
        buffer.redo()
        expect(buffer.getText()).toBe "hey\nlittle worms\r\nhow are you digging?"

      it "does not push the transaction to the undo stack if it is empty", ->
        buffer.transact ->
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

        buffer.redo()
        buffer.transact -> buffer.abortTransaction()
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      it "halts execution undoes all operations since the beginning of the transaction if ::abortTransaction() is called", ->
        continuedPastAbort = false
        buffer.transact ->
          buffer.setTextInRange([[0, 2], [0, 5]], "y")
          buffer.setTextInRange([[2, 13], [2, 14]], "igg")
          buffer.abortTransaction()
          continuedPastAbort = true

        expect(continuedPastAbort).toBe false

        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

        buffer.redo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        buffer.redo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

      it "preserves the redo stack until a content change occurs", ->
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

        # no changes occur in this transaction before aborting
        buffer.transact ->
          buffer.markRange([[0, 0], [0, 5]])
          buffer.abortTransaction()
          buffer.setTextInRange([[0, 0], [0, 5]], "hey")

        buffer.redo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

        buffer.transact ->
          buffer.setTextInRange([[0, 0], [0, 5]], "hey")
          buffer.abortTransaction()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

        buffer.redo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      it "allows nested transactions", ->
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        buffer.transact ->
          buffer.setTextInRange([[0, 2], [0, 5]], "y")
          buffer.transact ->
            buffer.setTextInRange([[2, 13], [2, 14]], "igg")
            buffer.setTextInRange([[2, 18], [2, 19]], "'")
          expect(buffer.getText()).toBe "hey\nworms\r\nhow are you diggin'?"
          buffer.undo()
          expect(buffer.getText()).toBe "hey\nworms\r\nhow are you doing?"
          buffer.redo()
          expect(buffer.getText()).toBe "hey\nworms\r\nhow are you diggin'?"

        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        buffer.redo()
        expect(buffer.getText()).toBe "hey\nworms\r\nhow are you diggin'?"

        buffer.undo()
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      it "groups adjacent transactions within each other's grouping intervals", ->
        now += 1000
        buffer.transact 101, -> buffer.setTextInRange([[0, 2], [0, 5]], "y")

        now += 100
        buffer.transact 201, -> buffer.setTextInRange([[0, 3], [0, 3]], "yy")

        now += 200
        buffer.transact 201, -> buffer.setTextInRange([[0, 5], [0, 5]], "yy")

        # not grouped because the previous transaction's grouping interval
        # is only 200ms and we've advanced 300ms
        now += 300
        buffer.transact 301, -> buffer.setTextInRange([[0, 7], [0, 7]], "!!")

        expect(buffer.getText()).toBe "heyyyyy!!\nworms\r\nhow are you doing?"

        buffer.undo()
        expect(buffer.getText()).toBe "heyyyyy\nworms\r\nhow are you doing?"

        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        buffer.redo()
        expect(buffer.getText()).toBe "heyyyyy\nworms\r\nhow are you doing?"

        buffer.redo()
        expect(buffer.getText()).toBe "heyyyyy!!\nworms\r\nhow are you doing?"

      it "allows undo/redo within transactions, but not beyond the start of the containing transaction", ->
        buffer.setText("")
        buffer.markPosition([0, 0])

        buffer.append("a")

        buffer.transact ->
          buffer.append("b")
          buffer.transact -> buffer.append("c")
          buffer.append("d")

          expect(buffer.undo()).toBe true
          expect(buffer.getText()).toBe "abc"

          expect(buffer.undo()).toBe true
          expect(buffer.getText()).toBe "ab"

          expect(buffer.undo()).toBe true
          expect(buffer.getText()).toBe "a"

          expect(buffer.undo()).toBe false
          expect(buffer.getText()).toBe "a"

          expect(buffer.redo()).toBe true
          expect(buffer.getText()).toBe "ab"

          expect(buffer.redo()).toBe true
          expect(buffer.getText()).toBe "abc"

          expect(buffer.redo()).toBe true
          expect(buffer.getText()).toBe "abcd"

          expect(buffer.redo()).toBe false
          expect(buffer.getText()).toBe "abcd"

        expect(buffer.undo()).toBe true
        expect(buffer.getText()).toBe "a"

      it "does not error if the buffer is destroyed in a change callback within the transaction", ->
        buffer.onDidChange -> buffer.destroy()
        result = buffer.transact ->
          buffer.append('!')
          'hi'
        expect(result).toBe('hi')

  describe "checkpoints", ->
    beforeEach ->
      buffer = new TextBuffer

    describe "::getChangesSinceCheckpoint(checkpoint)", ->
      it "returns a list of changes that have been made since the checkpoint", ->
        buffer.setText('abc\ndef\nghi\njkl\n')
        buffer.append("mno\n")
        checkpoint = buffer.createCheckpoint()
        buffer.transact ->
          buffer.append('pqr\n')
          buffer.append('stu\n')
        buffer.append('vwx\n')
        buffer.setTextInRange([[1, 0], [1, 2]], 'yz')

        expect(buffer.getText()).toBe 'abc\nyzf\nghi\njkl\nmno\npqr\nstu\nvwx\n'
        assertChangesEqual(buffer.getChangesSinceCheckpoint(checkpoint), [
          {
            oldRange: [[1, 0], [1, 2]],
            newRange: [[1, 0], [1, 2]],
            oldText: "de",
            newText: "yz",
          },
          {
            oldRange: [[5, 0], [5, 0]],
            newRange: [[5, 0], [8, 0]],
            oldText: "",
            newText: "pqr\nstu\nvwx\n",
          }
        ])

      it "returns an empty list of changes when no change has been made since the checkpoint", ->
        checkpoint = buffer.createCheckpoint()
        expect(buffer.getChangesSinceCheckpoint(checkpoint)).toEqual []

      it "returns an empty list of changes when the checkpoint doesn't exist", ->
        buffer.transact ->
          buffer.append('abc\n')
          buffer.append('def\n')
        buffer.append('ghi\n')
        expect(buffer.getChangesSinceCheckpoint(-1)).toEqual []

    describe "::revertToCheckpoint(checkpoint)", ->
      it "undoes all changes following the checkpoint", ->
        buffer.append("hello")
        checkpoint = buffer.createCheckpoint()

        buffer.transact ->
          buffer.append("\n")
          buffer.append("world")

        buffer.append("\n")
        buffer.append("how are you?")

        result = buffer.revertToCheckpoint(checkpoint)
        expect(result).toBe(true)
        expect(buffer.getText()).toBe("hello")

        buffer.redo()
        expect(buffer.getText()).toBe("hello")

    describe "::groupChangesSinceCheckpoint(checkpoint)", ->
      it "combines all changes since the checkpoint into a single transaction", ->
        historyLayer = buffer.addMarkerLayer(maintainHistory: true)

        buffer.append("one\n")
        marker = historyLayer.markRange([[0, 1], [0, 2]])
        marker.setProperties(a: 'b')

        checkpoint = buffer.createCheckpoint()
        buffer.append("two\n")
        buffer.transact ->
          buffer.append("three\n")
          buffer.append("four")

        marker.setRange([[0, 1], [2, 3]])
        marker.setProperties(a: 'c')
        result = buffer.groupChangesSinceCheckpoint(checkpoint)

        expect(result).toBeTruthy()
        expect(buffer.getText()).toBe """
          one
          two
          three
          four
        """
        expect(marker.getRange()).toEqual [[0, 1], [2, 3]]
        expect(marker.getProperties()).toEqual {a: 'c'}

        buffer.undo()
        expect(buffer.getText()).toBe("one\n")
        expect(marker.getRange()).toEqual [[0, 1], [0, 2]]
        expect(marker.getProperties()).toEqual {a: 'b'}

        buffer.redo()
        expect(buffer.getText()).toBe """
          one
          two
          three
          four
        """
        expect(marker.getRange()).toEqual [[0, 1], [2, 3]]
        expect(marker.getProperties()).toEqual {a: 'c'}

      it "skips any later checkpoints when grouping changes", ->
        buffer.append("one\n")
        checkpoint = buffer.createCheckpoint()
        buffer.append("two\n")
        checkpoint2 = buffer.createCheckpoint()
        buffer.append("three")

        buffer.groupChangesSinceCheckpoint(checkpoint)
        expect(buffer.revertToCheckpoint(checkpoint2)).toBe(false)

        expect(buffer.getText()).toBe """
          one
          two
          three
        """

        buffer.undo()
        expect(buffer.getText()).toBe("one\n")

        buffer.redo()
        expect(buffer.getText()).toBe """
          one
          two
          three
        """

      it "does nothing when no changes have been made since the checkpoint", ->
        buffer.append("one\n")
        checkpoint = buffer.createCheckpoint()
        result = buffer.groupChangesSinceCheckpoint(checkpoint)
        expect(result).toBeTruthy()
        buffer.undo()
        expect(buffer.getText()).toBe ""

      it "returns false and does nothing when the checkpoint is not in the buffer's history", ->
        buffer.append("hello\n")
        checkpoint = buffer.createCheckpoint()
        buffer.undo()
        buffer.append("world")
        result = buffer.groupChangesSinceCheckpoint(checkpoint)
        expect(result).toBeFalsy()
        buffer.undo()
        expect(buffer.getText()).toBe ""

    it "skips checkpoints when undoing", ->
      buffer.append("hello")
      buffer.createCheckpoint()
      buffer.createCheckpoint()
      buffer.createCheckpoint()
      buffer.undo()
      expect(buffer.getText()).toBe("")

    it "preserves checkpoints across undo and redo", ->
      buffer.append("a")
      buffer.append("b")
      checkpoint1 = buffer.createCheckpoint()
      buffer.append("c")
      checkpoint2 = buffer.createCheckpoint()

      buffer.undo()
      expect(buffer.getText()).toBe("ab")

      buffer.redo()
      expect(buffer.getText()).toBe("abc")

      buffer.append("d")

      expect(buffer.revertToCheckpoint(checkpoint2)).toBe true
      expect(buffer.getText()).toBe("abc")
      expect(buffer.revertToCheckpoint(checkpoint1)).toBe true
      expect(buffer.getText()).toBe("ab")

    it "handles checkpoints created when there have been no changes", ->
      checkpoint = buffer.createCheckpoint()
      buffer.undo()
      buffer.append("hello")
      buffer.revertToCheckpoint(checkpoint)
      expect(buffer.getText()).toBe("")

    it "returns false when the checkpoint is not in the buffer's history", ->
      buffer.append("hello\n")
      checkpoint = buffer.createCheckpoint()
      buffer.undo()
      buffer.append("world")
      expect(buffer.revertToCheckpoint(checkpoint)).toBe(false)
      expect(buffer.getText()).toBe("world")

    it "does not allow changes based on checkpoints outside of the current transaction", ->
      checkpoint = buffer.createCheckpoint()

      buffer.append("a")

      buffer.transact ->
        expect(buffer.revertToCheckpoint(checkpoint)).toBe false
        expect(buffer.getText()).toBe "a"

        buffer.append("b")

        expect(buffer.groupChangesSinceCheckpoint(checkpoint)).toBeFalsy()

      buffer.undo()
      expect(buffer.getText()).toBe "a"

  describe "::groupLastChanges()", ->
    it "groups the last two changes into a single transaction", ->
      buffer = new TextBuffer()
      layer = buffer.addMarkerLayer({maintainHistory: true})

      buffer.append('a')

      # Group two transactions, ensure before/after markers snapshots are preserved
      marker = layer.markPosition([0, 0])
      buffer.transact ->
        buffer.append('b')
      buffer.createCheckpoint()
      buffer.transact ->
        buffer.append('ccc')
        marker.setHeadPosition([0, 2])

      expect(buffer.groupLastChanges()).toBe(true)
      buffer.undo()
      expect(marker.getHeadPosition()).toEqual([0, 0])
      expect(buffer.getText()).toBe('a')
      buffer.redo()
      expect(marker.getHeadPosition()).toEqual([0, 2])
      buffer.undo()

      # Group two bare changes
      buffer.transact ->
        buffer.append('b')
        buffer.createCheckpoint()
        buffer.append('c')
        expect(buffer.groupLastChanges()).toBe(true)
        buffer.undo()
        expect(buffer.getText()).toBe('a')

      # Group a transaction with a bare change
      buffer.transact ->
        buffer.transact ->
          buffer.append('b')
          buffer.append('c')
        buffer.append('d')
        expect(buffer.groupLastChanges()).toBe(true)
        buffer.undo()
        expect(buffer.getText()).toBe('a')

      # Group a bare change with a transaction
      buffer.transact ->
        buffer.append('b')
        buffer.transact ->
          buffer.append('c')
          buffer.append('d')
        expect(buffer.groupLastChanges()).toBe(true)
        buffer.undo()
        expect(buffer.getText()).toBe('a')

      # Can't group past the beginning of an open transaction
      buffer.transact ->
        expect(buffer.groupLastChanges()).toBe(false)
        buffer.append('b')
        expect(buffer.groupLastChanges()).toBe(false)
        buffer.append('c')
        expect(buffer.groupLastChanges()).toBe(true)
        buffer.undo()
        expect(buffer.getText()).toBe('a')

  describe "::setHistoryProvider(provider)", ->
    it "replaces the currently active history provider with the passed one", ->
      buffer = new TextBuffer({text: ''})
      buffer.insert([0, 0], 'Lorem ')
      buffer.insert([0, 6], 'ipsum ')
      expect(buffer.getText()).toBe('Lorem ipsum ')

      buffer.undo()
      expect(buffer.getText()).toBe('Lorem ')

      buffer.setHistoryProvider(new DefaultHistoryProvider(buffer))
      buffer.undo()
      expect(buffer.getText()).toBe('Lorem ')

      buffer.insert([0, 6], 'dolor ')
      expect(buffer.getText()).toBe('Lorem dolor ')

      buffer.undo()
      expect(buffer.getText()).toBe('Lorem ')

  describe "::getHistory(maxEntries) and restoreDefaultHistoryProvider(history)", ->
    it "returns a base text and the state of the last `maxEntries` entries in the undo and redo stacks", ->
      buffer = new TextBuffer({text: ''})
      markerLayer = buffer.addMarkerLayer({maintainHistory: true})

      buffer.append('Lorem ')
      buffer.append('ipsum ')
      buffer.append('dolor ')
      markerLayer.markPosition([0, 2])
      markersSnapshotAtCheckpoint1 = buffer.createMarkerSnapshot()
      checkpoint1 = buffer.createCheckpoint()
      buffer.append('sit ')
      buffer.append('amet ')
      buffer.append('consecteur ')
      markerLayer.markPosition([0, 4])
      markersSnapshotAtCheckpoint2 = buffer.createMarkerSnapshot()
      checkpoint2 = buffer.createCheckpoint()
      buffer.append('adipiscit ')
      buffer.append('elit ')
      buffer.undo()
      buffer.undo()
      buffer.undo()

      history = buffer.getHistory(3)
      expect(history.baseText).toBe('Lorem ipsum dolor ')
      expect(history.nextCheckpointId).toBe(buffer.createCheckpoint())
      expect(history.undoStack).toEqual([
        {
          type: 'checkpoint',
          id: checkpoint1,
          markers: markersSnapshotAtCheckpoint1
        },
        {
          type: 'transaction',
          changes: [{oldStart: Point(0, 18), oldEnd: Point(0, 18), newStart: Point(0, 18), newEnd: Point(0, 22), oldText: '', newText: 'sit '}],
          markersBefore: markersSnapshotAtCheckpoint1,
          markersAfter: markersSnapshotAtCheckpoint1
        },
        {
          type: 'transaction',
          changes: [{oldStart: Point(0, 22), oldEnd: Point(0, 22), newStart: Point(0, 22), newEnd: Point(0, 27), oldText: '', newText: 'amet '}],
          markersBefore: markersSnapshotAtCheckpoint1,
          markersAfter: markersSnapshotAtCheckpoint1
        }
      ])
      expect(history.redoStack).toEqual([
        {
          type: 'transaction',
          changes: [{oldStart: Point(0, 38), oldEnd: Point(0, 38), newStart: Point(0, 38), newEnd: Point(0, 48), oldText: '', newText: 'adipiscit '}],
          markersBefore: markersSnapshotAtCheckpoint2,
          markersAfter: markersSnapshotAtCheckpoint2
        },
        {
          type: 'checkpoint',
          id: checkpoint2,
          markers: markersSnapshotAtCheckpoint2
        },
        {
          type: 'transaction',
          changes: [{oldStart: Point(0, 27), oldEnd: Point(0, 27), newStart: Point(0, 27), newEnd: Point(0, 38), oldText: '', newText: 'consecteur '}],
          markersBefore: markersSnapshotAtCheckpoint1,
          markersAfter: markersSnapshotAtCheckpoint1
        }
      ])

      buffer.createCheckpoint()
      buffer.append('x')
      buffer.undo()
      buffer.clearUndoStack()

      expect(buffer.getHistory()).not.toEqual(history)
      buffer.restoreDefaultHistoryProvider(history)
      expect(buffer.getHistory()).toEqual(history)

    it "throws an error when called within a transaction", ->
      buffer = new TextBuffer()
      expect(->
        buffer.transact(-> buffer.getHistory(3))
      ).toThrowError()

  describe "::getTextInRange(range)", ->
    it "returns the text in a given range", ->
      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      expect(buffer.getTextInRange([[1, 1], [1, 4]])).toBe "orl"
      expect(buffer.getTextInRange([[0, 3], [2, 3]])).toBe "lo\nworld\r\nhow"
      expect(buffer.getTextInRange([[0, 0], [2, 18]])).toBe buffer.getText()

    it "clips the given range", ->
      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      expect(buffer.getTextInRange([[-100, -100], [100, 100]])).toBe buffer.getText()

  describe "::clipPosition(position)", ->
    it "returns a valid position closest to the given position", ->
      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      expect(buffer.clipPosition([-1, -1])).toEqual [0, 0]
      expect(buffer.clipPosition([-1, 2])).toEqual [0, 0]
      expect(buffer.clipPosition([0, -1])).toEqual [0, 0]
      expect(buffer.clipPosition([0, 20])).toEqual [0, 5]
      expect(buffer.clipPosition([1, -1])).toEqual [1, 0]
      expect(buffer.clipPosition([1, 20])).toEqual [1, 5]
      expect(buffer.clipPosition([10, 0])).toEqual [2, 18]
      expect(buffer.clipPosition([Infinity, 0])).toEqual [2, 18]

    it "throws an error when given an invalid point", ->
      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      expect -> buffer.clipPosition([NaN, 1])
        .toThrowError("Invalid Point: (NaN, 1)")
      expect -> buffer.clipPosition([0, NaN])
        .toThrowError("Invalid Point: (0, NaN)")
      expect -> buffer.clipPosition([0, {}])
        .toThrowError("Invalid Point: (0, [object Object])")

  describe "::characterIndexForPosition(position)", ->
    beforeEach ->
      buffer = new TextBuffer(text: "zero\none\r\ntwo\nthree")

    it "returns the absolute character offset for the given position", ->
      expect(buffer.characterIndexForPosition([0, 0])).toBe 0
      expect(buffer.characterIndexForPosition([0, 1])).toBe 1
      expect(buffer.characterIndexForPosition([0, 4])).toBe 4
      expect(buffer.characterIndexForPosition([1, 0])).toBe 5
      expect(buffer.characterIndexForPosition([1, 1])).toBe 6
      expect(buffer.characterIndexForPosition([1, 3])).toBe 8
      expect(buffer.characterIndexForPosition([2, 0])).toBe 10
      expect(buffer.characterIndexForPosition([2, 1])).toBe 11
      expect(buffer.characterIndexForPosition([3, 0])).toBe 14
      expect(buffer.characterIndexForPosition([3, 5])).toBe 19

    it "clips the given position before translating", ->
      expect(buffer.characterIndexForPosition([-1, -1])).toBe 0
      expect(buffer.characterIndexForPosition([1, 100])).toBe 8
      expect(buffer.characterIndexForPosition([100, 100])).toBe 19

  describe "::positionForCharacterIndex(offset)", ->
    beforeEach ->
      buffer = new TextBuffer(text: "zero\none\r\ntwo\nthree")

    it "returns the position for the given absolute character offset", ->
      expect(buffer.positionForCharacterIndex(0)).toEqual [0, 0]
      expect(buffer.positionForCharacterIndex(1)).toEqual [0, 1]
      expect(buffer.positionForCharacterIndex(4)).toEqual [0, 4]
      expect(buffer.positionForCharacterIndex(5)).toEqual [1, 0]
      expect(buffer.positionForCharacterIndex(6)).toEqual [1, 1]
      expect(buffer.positionForCharacterIndex(8)).toEqual [1, 3]
      expect(buffer.positionForCharacterIndex(10)).toEqual [2, 0]
      expect(buffer.positionForCharacterIndex(11)).toEqual [2, 1]
      expect(buffer.positionForCharacterIndex(14)).toEqual [3, 0]
      expect(buffer.positionForCharacterIndex(19)).toEqual [3, 5]

    it "clips the given offset before translating", ->
      expect(buffer.positionForCharacterIndex(-1)).toEqual [0, 0]
      expect(buffer.positionForCharacterIndex(20)).toEqual [3, 5]

  describe "serialization", ->
    expectSameMarkers = (left, right) ->
      markers1 = left.getMarkers().sort (a, b) -> a.compare(b)
      markers2 = right.getMarkers().sort (a, b) -> a.compare(b)
      expect(markers1.length).toBe markers2.length
      for marker1, i in markers1
        expect(marker1).toEqual(markers2[i])
      return

    it "can serialize / deserialize the buffer along with its history, marker layers, and display layers", (done) ->
      bufferA = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      displayLayer1A = bufferA.addDisplayLayer()
      displayLayer2A = bufferA.addDisplayLayer()
      displayLayer1A.foldBufferRange([[0, 1], [0, 3]])
      displayLayer2A.foldBufferRange([[0, 0], [0, 2]])
      bufferA.createCheckpoint()
      bufferA.setTextInRange([[0, 5], [0, 5]], " there")
      bufferA.transact -> bufferA.setTextInRange([[1, 0], [1, 5]], "friend")
      layerA = bufferA.addMarkerLayer(maintainHistory: true, persistent: true)
      layerA.markRange([[0, 6], [0, 8]], reversed: true, foo: 1)
      marker2A = bufferA.markPosition([2, 2], bar: 2)
      bufferA.transact ->
        bufferA.setTextInRange([[1, 0], [1, 0]], "good ")
        bufferA.append("?")
        marker2A.setProperties(bar: 3, baz: 4)
      layerA.markRange([[0, 4], [0, 5]], invalidate: 'inside')
      bufferA.setTextInRange([[0, 5], [0, 5]], "oo")
      bufferA.undo()

      state = JSON.parse(JSON.stringify(bufferA.serialize()))
      TextBuffer.deserialize(state).then (bufferB) ->
        expect(bufferB.getText()).toBe "hello there\ngood friend\r\nhow are you doing??"
        expectSameMarkers(bufferB.getMarkerLayer(layerA.id), layerA)
        expect(bufferB.getDisplayLayer(displayLayer1A.id).foldsIntersectingBufferRange([[0, 1], [0, 3]]).length).toBe(1)
        expect(bufferB.getDisplayLayer(displayLayer2A.id).foldsIntersectingBufferRange([[0, 0], [0, 2]]).length).toBe(1)
        displayLayer3B = bufferB.addDisplayLayer()
        expect(displayLayer3B.id).toBeGreaterThan(displayLayer1A.id)
        expect(displayLayer3B.id).toBeGreaterThan(displayLayer2A.id)

        bufferA.redo()
        bufferB.redo()
        expect(bufferB.getText()).toBe "hellooo there\ngood friend\r\nhow are you doing??"
        expectSameMarkers(bufferB.getMarkerLayer(layerA.id), layerA)
        expect(bufferB.getMarkerLayer(layerA.id).maintainHistory).toBe true
        expect(bufferB.getMarkerLayer(layerA.id).persistent).toBe true

        bufferA.undo()
        bufferB.undo()
        expect(bufferB.getText()).toBe "hello there\ngood friend\r\nhow are you doing??"
        expectSameMarkers(bufferB.getMarkerLayer(layerA.id), layerA)

        bufferA.undo()
        bufferB.undo()
        expect(bufferB.getText()).toBe "hello there\nfriend\r\nhow are you doing?"
        expectSameMarkers(bufferB.getMarkerLayer(layerA.id), layerA)

        bufferA.undo()
        bufferB.undo()
        expect(bufferB.getText()).toBe "hello there\nworld\r\nhow are you doing?"
        expectSameMarkers(bufferB.getMarkerLayer(layerA.id), layerA)

        bufferA.undo()
        bufferB.undo()
        expect(bufferB.getText()).toBe "hello\nworld\r\nhow are you doing?"
        expectSameMarkers(bufferB.getMarkerLayer(layerA.id), layerA)

        # Accounts for deserialized markers when selecting the next marker's id
        marker3A = layerA.markRange([[0, 1], [2, 3]])
        marker3B = bufferB.getMarkerLayer(layerA.id).markRange([[0, 1], [2, 3]])
        expect(marker3B.id).toBe marker3A.id

        # Doesn't try to reload the buffer since it has no file.
        setTimeout(->
          expect(bufferB.getText()).toBe "hello\nworld\r\nhow are you doing?"
          done()
        , 50)

    it "serializes / deserializes the buffer's persistent custom marker layers", (done) ->
      bufferA = new TextBuffer("abcdefghijklmnopqrstuvwxyz")

      layer1A = bufferA.addMarkerLayer()
      layer2A = bufferA.addMarkerLayer(persistent: true)

      layer1A.markRange([[0, 1], [0, 2]])
      layer1A.markRange([[0, 3], [0, 4]])

      layer2A.markRange([[0, 5], [0, 6]])
      layer2A.markRange([[0, 7], [0, 8]])

      TextBuffer.deserialize(JSON.parse(JSON.stringify(bufferA.serialize()))).then (bufferB) ->
        layer1B = bufferB.getMarkerLayer(layer1A.id)
        layer2B = bufferB.getMarkerLayer(layer2A.id)
        expect(layer2B.persistent).toBe true

        expect(layer1B).toBe undefined
        expectSameMarkers(layer2A, layer2B)
        done()

    it "doesn't serialize the default marker layer", (done) ->
      bufferA = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      markerLayerA = bufferA.getDefaultMarkerLayer()
      marker1A = bufferA.markRange([[0, 1], [1, 2]], foo: 1)

      TextBuffer.deserialize(bufferA.serialize()).then (bufferB) ->
        markerLayerB = bufferB.getDefaultMarkerLayer()
        expect(bufferB.getMarker(marker1A.id)).toBeUndefined()
        done()

    it "doesn't attempt to serialize snapshots for destroyed marker layers", ->
      buffer = new TextBuffer(text: "abc")
      markerLayer = buffer.addMarkerLayer(maintainHistory: true, persistent: true)
      markerLayer.markPosition([0, 3])
      buffer.insert([0, 0], 'x')
      markerLayer.destroy()

      expect(-> buffer.serialize()).not.toThrowError()

    it "doesn't remember marker layers when calling serialize with {markerLayers: false}", (done) ->
      bufferA = new TextBuffer(text: "world")
      layerA = bufferA.addMarkerLayer(maintainHistory: true)
      markerA = layerA.markPosition([0, 3])
      markerB = null
      bufferA.transact ->
        bufferA.insert([0, 0], 'hello ')
        markerB = layerA.markPosition([0, 5])
      bufferA.undo()

      TextBuffer.deserialize(bufferA.serialize({markerLayers: false})).then (bufferB) ->
        expect(bufferB.getText()).toBe("world")
        expect(bufferB.getMarkerLayer(layerA.id)?.getMarker(markerA.id)).toBeUndefined()
        expect(bufferB.getMarkerLayer(layerA.id)?.getMarker(markerB.id)).toBeUndefined()

        bufferB.redo()
        expect(bufferB.getText()).toBe("hello world")
        expect(bufferB.getMarkerLayer(layerA.id)?.getMarker(markerA.id)).toBeUndefined()
        expect(bufferB.getMarkerLayer(layerA.id)?.getMarker(markerB.id)).toBeUndefined()

        bufferB.undo()
        expect(bufferB.getText()).toBe("world")
        expect(bufferB.getMarkerLayer(layerA.id)?.getMarker(markerA.id)).toBeUndefined()
        expect(bufferB.getMarkerLayer(layerA.id)?.getMarker(markerB.id)).toBeUndefined()
        done()

    it "doesn't remember history when calling serialize with {history: false}", (done) ->
      bufferA = new TextBuffer(text: 'abc')
      bufferA.append('def')
      bufferA.append('ghi')

      TextBuffer.deserialize(bufferA.serialize({history: false})).then (bufferB) ->
        expect(bufferB.getText()).toBe("abcdefghi")
        expect(bufferB.undo()).toBe(false)
        expect(bufferB.getText()).toBe("abcdefghi")
        done()

    it "serializes / deserializes the buffer's unique identifier", (done) ->
      bufferA = new TextBuffer()
      TextBuffer.deserialize(JSON.parse(JSON.stringify(bufferA.serialize()))).then (bufferB) ->
        expect(bufferB.getId()).toEqual(bufferA.getId())
        done()

    it "doesn't deserialize a state that was serialized with a different buffer version", ->
      bufferA = new TextBuffer()
      serializedBuffer = JSON.parse(JSON.stringify(bufferA.serialize()))
      serializedBuffer.version = 123456789

      expect(TextBuffer.deserialize(serializedBuffer)).toBeUndefined()

    it "doesn't deserialize a state referencing a file that no longer exists", (done) ->
      tempDir = fs.realpathSync(temp.mkdirSync('text-buffer'))
      filePath = join(tempDir, 'file.txt')
      fs.writeFileSync(filePath, "something\n")

      bufferA = TextBuffer.loadSync(filePath)
      state = bufferA.serialize()

      fs.unlinkSync(filePath)

      state.mustExist = true
      TextBuffer.deserialize(state).then(
        -> expect('serialization succeeded with mustExist: true').toBeUndefined(),
        (err) -> expect(err.code).toBe('ENOENT')
      ).then(done, done)

    describe "when the serialized buffer was unsaved and had no path", ->
      it "restores the previous unsaved state of the buffer", ->
        buffer = new TextBuffer()
        buffer.setText("abc")

        TextBuffer.deserialize(buffer.serialize()).then (buffer2) ->
          expect(buffer2.getPath()).toBeUndefined()
          expect(buffer2.getText()).toBe("abc")

  describe "::getRange()", ->
    it "returns the range of the entire buffer text", ->
      buffer = new TextBuffer("abc\ndef\nghi")
      expect(buffer.getRange()).toEqual [[0, 0], [2, 3]]

  describe "::getLength()", ->
    it "returns the lenght of the entire buffer text", ->
      buffer = new TextBuffer("abc\ndef\nghi")
      expect(buffer.getLength()).toBe("abc\ndef\nghi".length)

  describe "::rangeForRow(row, includeNewline)", ->
    beforeEach ->
      buffer = new TextBuffer("this\nis a test\r\ntesting")

    describe "if includeNewline is false (the default)", ->
      it "returns a range from the beginning of the line to the end of the line", ->
        expect(buffer.rangeForRow(0)).toEqual([[0, 0], [0, 4]])
        expect(buffer.rangeForRow(1)).toEqual([[1, 0], [1, 9]])
        expect(buffer.rangeForRow(2)).toEqual([[2, 0], [2, 7]])

    describe "if includeNewline is true", ->
      it "returns a range from the beginning of the line to the beginning of the next (if it exists)", ->
        expect(buffer.rangeForRow(0, true)).toEqual([[0, 0], [1, 0]])
        expect(buffer.rangeForRow(1, true)).toEqual([[1, 0], [2, 0]])
        expect(buffer.rangeForRow(2, true)).toEqual([[2, 0], [2, 7]])

    describe "if the given row is out of range", ->
      it "returns the range of the nearest valid row", ->
        expect(buffer.rangeForRow(-1)).toEqual([[0, 0], [0, 4]])
        expect(buffer.rangeForRow(10)).toEqual([[2, 0], [2, 7]])

  describe "::onDidChangePath()", ->
    [filePath, newPath, bufferToChange, eventHandler] = []

    beforeEach ->
      tempDir = fs.realpathSync(temp.mkdirSync('text-buffer'))
      filePath = join(tempDir, "manipulate-me")
      newPath = "#{filePath}-i-moved"
      fs.writeFileSync(filePath, "")
      bufferToChange = TextBuffer.loadSync(filePath)

    afterEach ->
      bufferToChange.destroy()
      fs.removeSync(filePath)
      fs.removeSync(newPath)

    it "notifies observers when the buffer is saved to a new path", (done) ->
      bufferToChange.onDidChangePath (p) ->
        expect(p).toBe(newPath)
        done()
      bufferToChange.saveAs(newPath)

    it "notifies observers when the buffer's file is moved", (done) ->
      # FIXME: This doesn't pass on Linux
      if process.platform in ['linux', 'win32']
        done()
        return

      bufferToChange.onDidChangePath (p) ->
        expect(p).toBe(newPath)
        done()

      fs.removeSync(newPath)
      fs.moveSync(filePath, newPath)

  describe "::onWillThrowWatchError", ->
    it "notifies observers when the file has a watch error", ->
      filePath = temp.openSync('atom').path
      fs.writeFileSync(filePath, '')

      buffer = TextBuffer.loadSync(filePath)

      eventHandler = jasmine.createSpy('eventHandler')
      buffer.onWillThrowWatchError(eventHandler)

      buffer.file.emitter.emit 'will-throw-watch-error', 'arg'
      expect(eventHandler).toHaveBeenCalledWith 'arg'

  describe "::getLines()", ->
    it "returns an array of lines in the text contents", ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = TextBuffer.loadSync(filePath)
      expect(buffer.getLines().length).toBe fileContents.split("\n").length
      expect(buffer.getLines().join('\n')).toBe fileContents

  describe "::setTextInRange(range, string)", ->
    changeHandler = null

    beforeEach (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      TextBuffer.load(filePath).then (result) ->
        buffer = result
        changeHandler = jasmine.createSpy('changeHandler')
        buffer.onDidChange changeHandler
        done()

    describe "when used to insert (called with an empty range and a non-empty string)", ->
      describe "when the given string has no newlines", ->
        it "inserts the string at the location of the given range", ->
          range = [[3, 4], [3, 4]]
          buffer.setTextInRange range, "foo"

          expect(buffer.lineForRow(2)).toBe "    if (items.length <= 1) return items;"
          expect(buffer.lineForRow(3)).toBe "    foovar pivot = items.shift(), current, left = [], right = [];"
          expect(buffer.lineForRow(4)).toBe "    while(items.length > 0) {"

          expect(changeHandler).toHaveBeenCalled()
          [event] = changeHandler.calls.allArgs()[0]
          expect(event.oldRange).toEqual range
          expect(event.newRange).toEqual [[3, 4], [3, 7]]
          expect(event.oldText).toBe ""
          expect(event.newText).toBe "foo"

      describe "when the given string has newlines", ->
        it "inserts the lines at the location of the given range", ->
          range = [[3, 4], [3, 4]]

          buffer.setTextInRange range, "foo\n\nbar\nbaz"

          expect(buffer.lineForRow(2)).toBe "    if (items.length <= 1) return items;"
          expect(buffer.lineForRow(3)).toBe "    foo"
          expect(buffer.lineForRow(4)).toBe ""
          expect(buffer.lineForRow(5)).toBe "bar"
          expect(buffer.lineForRow(6)).toBe "bazvar pivot = items.shift(), current, left = [], right = [];"
          expect(buffer.lineForRow(7)).toBe "    while(items.length > 0) {"

          expect(changeHandler).toHaveBeenCalled()
          [event] = changeHandler.calls.allArgs()[0]
          expect(event.oldRange).toEqual range
          expect(event.newRange).toEqual [[3, 4], [6, 3]]
          expect(event.oldText).toBe ""
          expect(event.newText).toBe "foo\n\nbar\nbaz"

    describe "when used to remove (called with a non-empty range and an empty string)", ->
      describe "when the range is contained within a single line", ->
        it "removes the characters within the range", ->
          range = [[3, 4], [3, 7]]
          buffer.setTextInRange range, ""

          expect(buffer.lineForRow(2)).toBe "    if (items.length <= 1) return items;"
          expect(buffer.lineForRow(3)).toBe "     pivot = items.shift(), current, left = [], right = [];"
          expect(buffer.lineForRow(4)).toBe "    while(items.length > 0) {"

          expect(changeHandler).toHaveBeenCalled()
          [event] = changeHandler.calls.allArgs()[0]
          expect(event.oldRange).toEqual range
          expect(event.newRange).toEqual [[3, 4], [3, 4]]
          expect(event.oldText).toBe "var"
          expect(event.newText).toBe ""

      describe "when the range spans 2 lines", ->
        it "removes the characters within the range and joins the lines", ->
          range = [[3, 16], [4, 4]]
          buffer.setTextInRange range, ""

          expect(buffer.lineForRow(2)).toBe "    if (items.length <= 1) return items;"
          expect(buffer.lineForRow(3)).toBe "    var pivot = while(items.length > 0) {"
          expect(buffer.lineForRow(4)).toBe "      current = items.shift();"

          expect(changeHandler).toHaveBeenCalled()
          [event] = changeHandler.calls.allArgs()[0]
          expect(event.oldRange).toEqual range
          expect(event.newRange).toEqual [[3, 16], [3, 16]]
          expect(event.oldText).toBe "items.shift(), current, left = [], right = [];\n    "
          expect(event.newText).toBe ""

      describe "when the range spans more than 2 lines", ->
        it "removes the characters within the range, joining the first and last line and removing the lines in-between", ->
          buffer.setTextInRange [[3, 16], [11, 9]], ""

          expect(buffer.lineForRow(2)).toBe "    if (items.length <= 1) return items;"
          expect(buffer.lineForRow(3)).toBe "    var pivot = sort(Array.apply(this, arguments));"
          expect(buffer.lineForRow(4)).toBe "};"

    describe "when used to replace text with other text (called with non-empty range and non-empty string)", ->
      it "replaces the old text with the new text", ->
        range = [[3, 16], [11, 9]]
        oldText = buffer.getTextInRange(range)

        buffer.setTextInRange range, "foo\nbar"

        expect(buffer.lineForRow(2)).toBe "    if (items.length <= 1) return items;"
        expect(buffer.lineForRow(3)).toBe "    var pivot = foo"
        expect(buffer.lineForRow(4)).toBe "barsort(Array.apply(this, arguments));"
        expect(buffer.lineForRow(5)).toBe "};"

        expect(changeHandler).toHaveBeenCalled()
        [event] = changeHandler.calls.allArgs()[0]
        expect(event.oldRange).toEqual range
        expect(event.newRange).toEqual [[3, 16], [4, 3]]
        expect(event.oldText).toBe oldText
        expect(event.newText).toBe "foo\nbar"

    it "allows a change to be undone safely from an ::onDidChange callback", ->
      buffer.onDidChange -> buffer.undo()
      buffer.setTextInRange([[0, 0], [0, 0]], "hello")
      expect(buffer.lineForRow(0)).toBe "var quicksort = function () {"

  describe "::setText(text)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = TextBuffer.loadSync(filePath)

    describe "when the buffer contains newlines", ->
      it "changes the entire contents of the buffer and emits a change event", ->
        lastRow = buffer.getLastRow()
        expectedPreRange = [[0, 0], [lastRow, buffer.lineForRow(lastRow).length]]
        changeHandler = jasmine.createSpy('changeHandler')
        buffer.onDidChange changeHandler

        newText = "I know you are.\nBut what am I?"
        buffer.setText(newText)

        expect(buffer.getText()).toBe newText
        expect(changeHandler).toHaveBeenCalled()

        [event] = changeHandler.calls.allArgs()[0]
        expect(event.newText).toBe newText
        expect(event.oldRange).toEqual expectedPreRange
        expect(event.newRange).toEqual [[0, 0], [1, 14]]

    describe "with windows newlines", ->
      it "changes the entire contents of the buffer", ->
        buffer = new TextBuffer("first\r\nlast")
        lastRow = buffer.getLastRow()
        expectedPreRange = [[0, 0], [lastRow, buffer.lineForRow(lastRow).length]]
        changeHandler = jasmine.createSpy('changeHandler')
        buffer.onDidChange changeHandler

        newText = "new first\r\nnew last"
        buffer.setText(newText)

        expect(buffer.getText()).toBe newText
        expect(changeHandler).toHaveBeenCalled()

        [event] = changeHandler.calls.allArgs()[0]
        expect(event.newText).toBe newText
        expect(event.oldRange).toEqual expectedPreRange
        expect(event.newRange).toEqual [[0, 0], [1, 8]]

  describe "::setTextViaDiff(text)", ->
    beforeEach (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      TextBuffer.load(filePath).then (result) ->
        buffer = result
        done()

    it "can change the entire contents of the buffer when there are no newlines", ->
      buffer.setText('BUFFER CHANGE')
      newText = 'DISK CHANGE'
      buffer.setTextViaDiff(newText)
      expect(buffer.getText()).toBe newText

    it "can change a buffer that contains lone carriage returns", ->
      oldText = 'one\rtwo\nthree\rfour\n'
      newText = 'one\rtwo and\nthree\rfour\n'
      buffer.setText(oldText)
      buffer.setTextViaDiff(newText)
      expect(buffer.getText()).toBe newText
      buffer.undo()
      expect(buffer.getText()).toBe oldText

    describe "with standard newlines", ->
      it "can change the entire contents of the buffer with no newline at the end", ->
        newText = "I know you are.\nBut what am I?"
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "can change the entire contents of the buffer with a newline at the end", ->
        newText = "I know you are.\nBut what am I?\n"
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "can change a few lines at the beginning in the buffer", ->
        newText = buffer.getText().replace(/function/g, 'omgwow')
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "can change a few lines in the middle of the buffer", ->
        newText = buffer.getText().replace(/shift/g, 'omgwow')
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "can adds a newline at the end", ->
        newText = buffer.getText() + '\n'
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

    describe "with windows newlines", ->
      beforeEach ->
        buffer.setText(buffer.getText().replace(/\n/g, '\r\n'))

      it "adds a newline at the end", ->
        newText = buffer.getText() + '\r\n'
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "changes the entire contents of the buffer with smaller content with no newline at the end", ->
        newText = "I know you are.\r\nBut what am I?"
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "changes the entire contents of the buffer with smaller content with newline at the end", ->
        newText = "I know you are.\r\nBut what am I?\r\n"
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "changes a few lines at the beginning in the buffer", ->
        newText = buffer.getText().replace(/function/g, 'omgwow')
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "changes a few lines in the middle of the buffer", ->
        newText = buffer.getText().replace(/shift/g, 'omgwow')
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

  describe "::getTextInRange(range)", ->
    beforeEach (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      TextBuffer.load(filePath).then (result) ->
        buffer = result
        done()

    describe "when range is empty", ->
      it "returns an empty string", ->
        range = [[1, 1], [1, 1]]
        expect(buffer.getTextInRange(range)).toBe ""

    describe "when range spans one line", ->
      it "returns characters in range", ->
        range = [[2, 8], [2, 13]]
        expect(buffer.getTextInRange(range)).toBe "items"

        lineLength = buffer.lineForRow(2).length
        range = [[2, 0], [2, lineLength]]
        expect(buffer.getTextInRange(range)).toBe "    if (items.length <= 1) return items;"

    describe "when range spans multiple lines", ->
      it "returns characters in range (including newlines)", ->
        lineLength = buffer.lineForRow(2).length
        range = [[2, 0], [3, 0]]
        expect(buffer.getTextInRange(range)).toBe "    if (items.length <= 1) return items;\n"

        lineLength = buffer.lineForRow(2).length
        range = [[2, 10], [4, 10]]
        expect(buffer.getTextInRange(range)).toBe "ems.length <= 1) return items;\n    var pivot = items.shift(), current, left = [], right = [];\n    while("

    describe "when the range starts before the start of the buffer", ->
      it "clips the range to the start of the buffer", ->
        expect(buffer.getTextInRange([[-Infinity, -Infinity], [0, Infinity]])).toBe buffer.lineForRow(0)

    describe "when the range ends after the end of the buffer", ->
      it "clips the range to the end of the buffer", ->
        expect(buffer.getTextInRange([[12], [13, Infinity]])).toBe buffer.lineForRow(12)

  describe "::scan(regex, fn)", ->
    beforeEach ->
      buffer = TextBuffer.loadSync(require.resolve('./fixtures/sample.js'))

    it "calls the given function with the information about each match", ->
      matches = []
      buffer.scan /current/g, (match) -> matches.push(match)
      expect(matches.length).toBe 5

      expect(matches[0].matchText).toBe 'current'
      expect(matches[0].range).toEqual [[3, 31], [3, 38]]
      expect(matches[0].lineText).toBe '    var pivot = items.shift(), current, left = [], right = [];'
      expect(matches[0].lineTextOffset).toBe 0
      expect(matches[0].leadingContextLines.length).toBe 0
      expect(matches[0].trailingContextLines.length).toBe 0

      expect(matches[1].matchText).toBe 'current'
      expect(matches[1].range).toEqual [[5, 6], [5, 13]]
      expect(matches[1].lineText).toBe '      current = items.shift();'
      expect(matches[1].lineTextOffset).toBe 0
      expect(matches[1].leadingContextLines.length).toBe 0
      expect(matches[1].trailingContextLines.length).toBe 0

    it "calls the given function with the information about each match including context lines", ->
      matches = []
      buffer.scan /current/g, {leadingContextLineCount: 1, trailingContextLineCount: 2}, (match) -> matches.push(match)
      expect(matches.length).toBe 5

      expect(matches[0].matchText).toBe 'current'
      expect(matches[0].range).toEqual [[3, 31], [3, 38]]
      expect(matches[0].lineText).toBe '    var pivot = items.shift(), current, left = [], right = [];'
      expect(matches[0].lineTextOffset).toBe 0
      expect(matches[0].leadingContextLines.length).toBe 1
      expect(matches[0].leadingContextLines[0]).toBe '    if (items.length <= 1) return items;'
      expect(matches[0].trailingContextLines.length).toBe 2
      expect(matches[0].trailingContextLines[0]).toBe '    while(items.length > 0) {'
      expect(matches[0].trailingContextLines[1]).toBe '      current = items.shift();'

      expect(matches[1].matchText).toBe 'current'
      expect(matches[1].range).toEqual [[5, 6], [5, 13]]
      expect(matches[1].lineText).toBe '      current = items.shift();'
      expect(matches[1].lineTextOffset).toBe 0
      expect(matches[1].leadingContextLines.length).toBe 1
      expect(matches[1].leadingContextLines[0]).toBe '    while(items.length > 0) {'
      expect(matches[1].trailingContextLines.length).toBe 2
      expect(matches[1].trailingContextLines[0]).toBe '      current < pivot ? left.push(current) : right.push(current);'
      expect(matches[1].trailingContextLines[1]).toBe '    }'

  describe "::backwardsScan(regex, fn)", ->
    beforeEach ->
      buffer = TextBuffer.loadSync(require.resolve('./fixtures/sample.js'))

    it "calls the given function with the information about each match in backwards order", ->
      matches = []
      buffer.backwardsScan /current/g, (match) -> matches.push(match)
      expect(matches.length).toBe 5

      expect(matches[0].matchText).toBe 'current'
      expect(matches[0].range).toEqual [[6, 56], [6, 63]]
      expect(matches[0].lineText).toBe '      current < pivot ? left.push(current) : right.push(current);'
      expect(matches[0].lineTextOffset).toBe 0
      expect(matches[0].leadingContextLines.length).toBe 0
      expect(matches[0].trailingContextLines.length).toBe 0

      expect(matches[1].matchText).toBe 'current'
      expect(matches[1].range).toEqual [[6, 34], [6, 41]]
      expect(matches[1].lineText).toBe '      current < pivot ? left.push(current) : right.push(current);'
      expect(matches[1].lineTextOffset).toBe 0
      expect(matches[1].leadingContextLines.length).toBe 0
      expect(matches[1].trailingContextLines.length).toBe 0

  describe "::scanInRange(range, regex, fn)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = TextBuffer.loadSync(filePath)

    describe "when given a regex with a ignore case flag", ->
      it "does a case-insensitive search", ->
        matches = []
        buffer.scanInRange /cuRRent/i, [[0, 0], [12, 0]], ({match, range}) ->
          matches.push(match)
        expect(matches.length).toBe 1

    describe "when given a regex with no global flag", ->
      it "calls the iterator with the first match for the given regex in the given range", ->
        matches = []
        ranges = []
        buffer.scanInRange /cu(rr)ent/, [[4, 0], [6, 44]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 1
        expect(ranges.length).toBe 1

        expect(matches[0][0]).toBe 'current'
        expect(matches[0][1]).toBe 'rr'
        expect(ranges[0]).toEqual [[5, 6], [5, 13]]

    describe "when given a regex with a global flag", ->
      it "calls the iterator with each match for the given regex in the given range", ->
        matches = []
        ranges = []
        buffer.scanInRange /cu(rr)ent/g, [[4, 0], [6, 59]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 3
        expect(ranges.length).toBe 3

        expect(matches[0][0]).toBe 'current'
        expect(matches[0][1]).toBe 'rr'
        expect(ranges[0]).toEqual [[5, 6], [5, 13]]

        expect(matches[1][0]).toBe 'current'
        expect(matches[1][1]).toBe 'rr'
        expect(ranges[1]).toEqual [[6, 6], [6, 13]]

        expect(matches[2][0]).toBe 'current'
        expect(matches[2][1]).toBe 'rr'
        expect(ranges[2]).toEqual [[6, 34], [6, 41]]

    describe "when the last regex match exceeds the end of the range", ->
      describe "when the portion of the match within the range also matches the regex", ->
        it "calls the iterator with the truncated match", ->
          matches = []
          ranges = []
          buffer.scanInRange /cu(r*)/g, [[4, 0], [6, 9]], ({match, range}) ->
            matches.push(match)
            ranges.push(range)

          expect(matches.length).toBe 2
          expect(ranges.length).toBe 2

          expect(matches[0][0]).toBe 'curr'
          expect(matches[0][1]).toBe 'rr'
          expect(ranges[0]).toEqual [[5, 6], [5, 10]]

          expect(matches[1][0]).toBe 'cur'
          expect(matches[1][1]).toBe 'r'
          expect(ranges[1]).toEqual [[6, 6], [6, 9]]

      describe "when the portion of the match within the range does not matches the regex", ->
        it "does not call the iterator with the truncated match", ->
          matches = []
          ranges = []
          buffer.scanInRange /cu(r*)e/g, [[4, 0], [6, 9]], ({match, range}) ->
            matches.push(match)
            ranges.push(range)

          expect(matches.length).toBe 1
          expect(ranges.length).toBe 1

          expect(matches[0][0]).toBe 'curre'
          expect(matches[0][1]).toBe 'rr'
          expect(ranges[0]).toEqual [[5, 6], [5, 11]]

    describe "when the iterator calls the 'replace' control function with a replacement string", ->
      it "replaces each occurrence of the regex match with the string", ->
        ranges = []
        buffer.scanInRange /cu(rr)ent/g, [[4, 0], [6, 59]], ({range, replace}) ->
          ranges.push(range)
          replace("foo")

        expect(ranges[0]).toEqual [[5, 6], [5, 13]]
        expect(ranges[1]).toEqual [[6, 6], [6, 13]]
        expect(ranges[2]).toEqual [[6, 30], [6, 37]]

        expect(buffer.lineForRow(5)).toBe '      foo = items.shift();'
        expect(buffer.lineForRow(6)).toBe '      foo < pivot ? left.push(foo) : right.push(current);'

      it "allows the match to be replaced with the empty string", ->
        buffer.scanInRange /current/g, [[4, 0], [6, 59]], ({replace}) ->
          replace("")

        expect(buffer.lineForRow(5)).toBe '       = items.shift();'
        expect(buffer.lineForRow(6)).toBe '       < pivot ? left.push() : right.push(current);'

    describe "when the iterator calls the 'stop' control function", ->
      it "stops the traversal", ->
        ranges = []
        buffer.scanInRange /cu(rr)ent/g, [[4, 0], [6, 59]], ({range, stop}) ->
          ranges.push(range)
          stop() if ranges.length is 2

        expect(ranges.length).toBe 2

    it "returns the same results as a regex match on a regular string", ->
      regexps = [
        /\w+/g                                   # 1 word
        /\w+\n\s*\w+/g,                          # 2 words separated by an newline (escape sequence)
        RegExp("\\w+\n\\s*\w+", 'g'),            # 2 words separated by a newline (literal)
        /\w+\s+\w+/g,                            # 2 words separated by some whitespace
        /\w+[^\w]+\w+/g,                         # 2 words separated by anything
        /\w+\n\s*\w+\n\s*\w+/g,                  # 3 words separated by newlines (escape sequence)
        RegExp("\\w+\n\\s*\\w+\n\\s*\\w+", 'g'), # 3 words separated by newlines (literal)
        /\w+[^\w]+\w+[^\w]+\w+/g,                # 3 words separated by anything
      ]

      i = 0
      while i < 20
        seed = Date.now()
        random = new Random(seed)

        text = buildRandomLines(random, 40)
        buffer = new TextBuffer({text})
        buffer.backwardsScanChunkSize = random.intBetween(100, 1000)

        range = getRandomBufferRange(random, buffer)
          .union(getRandomBufferRange(random, buffer))
          .union(getRandomBufferRange(random, buffer))
        regex = regexps[random(regexps.length)]

        expectedMatches = buffer.getTextInRange(range).match(regex) ? []
        continue unless expectedMatches.length > 0
        i++

        forwardRanges = []
        forwardMatches = []
        buffer.scanInRange regex, range, ({range, matchText}) ->
          forwardRanges.push(range)
          forwardMatches.push(matchText)
        expect(forwardMatches).toEqual(expectedMatches, "Seed: #{seed}")

        backwardRanges = []
        backwardMatches = []
        buffer.backwardsScanInRange regex, range, ({range, matchText}) ->
          backwardRanges.push(range)
          backwardMatches.push(matchText)
        expect(backwardMatches).toEqual(expectedMatches.reverse(), "Seed: #{seed}")

    it "does not return empty matches at the end of the range", ->
      ranges = []
      buffer.scanInRange /[ ]*/gm, [[0, 29], [1, 2]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[0, 29], [0, 29]], [[1, 0], [1, 2]]])

      ranges.length = 0
      buffer.scanInRange /[ ]*/gm, [[1, 0], [1, 2]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[1, 0], [1, 2]]])

      ranges.length = 0
      buffer.scanInRange /\s*/gm, [[0, 29], [1, 2]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[0, 29], [1, 2]]])

      ranges.length = 0
      buffer.scanInRange /\s*/gm, [[1, 0], [1, 2]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[1, 0], [1, 2]]])

    it "allows empty matches at the end of a range, when the range ends at column 0", ->
      ranges = []
      buffer.scanInRange /^[ ]*/gm, [[9, 0], [10, 0]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[9, 0], [9, 2]], [[10, 0], [10, 0]]])

      ranges.length = 0
      buffer.scanInRange /^[ ]*/gm, [[10, 0], [10, 0]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[10, 0], [10, 0]]])

      ranges.length = 0
      buffer.scanInRange /^\s*/gm, [[9, 0], [10, 0]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[9, 0], [9, 2]], [[10, 0], [10, 0]]])

      ranges.length = 0
      buffer.scanInRange /^\s*/gm, [[10, 0], [10, 0]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[10, 0], [10, 0]]])

      ranges.length = 0
      buffer.scanInRange /^\s*/gm, [[11, 0], [12, 0]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[11, 0], [11, 2]], [[12, 0], [12, 0]]])

    it "handles multi-line patterns", ->
      matchStrings = []

      # The '\s' character class
      buffer.scan /{\s+var/, ({matchText}) -> matchStrings.push(matchText)
      expect(matchStrings).toEqual(['{\n  var'])

      # A literal newline character
      matchStrings.length = 0
      buffer.scan RegExp("{\n  var"), ({matchText}) -> matchStrings.push(matchText)
      expect(matchStrings).toEqual(['{\n  var'])

      # A '\n' escape sequence
      matchStrings.length = 0
      buffer.scan /{\n  var/, ({matchText}) -> matchStrings.push(matchText)
      expect(matchStrings).toEqual(['{\n  var'])

      # A negated character class in the middle of the pattern
      matchStrings.length = 0
      buffer.scan /{[^a]  var/, ({matchText}) -> matchStrings.push(matchText)
      expect(matchStrings).toEqual(['{\n  var'])

      # A negated character class at the beginning of the pattern
      matchStrings.length = 0
      buffer.scan /[^a]  var/, ({matchText}) -> matchStrings.push(matchText)
      expect(matchStrings).toEqual(['\n  var'])

  describe "::find(regex)", ->
    it "resolves with the first range that matches the given regex", (done) ->
      buffer = new TextBuffer('abc\ndefghi')
      buffer.find(/\wf\w*/).then (range) ->
        expect(range).toEqual(Range(Point(1, 1), Point(1, 6)))
        done()

  describe "::findAllSync(regex)", ->
    it "returns all the ranges that match the given regex", ->
      buffer = new TextBuffer('abc\ndefghi')
      expect(buffer.findAllSync(/[bf]\w+/)).toEqual([
        Range(Point(0, 1), Point(0, 3)),
        Range(Point(1, 2), Point(1, 6)),
      ])

  describe "::findAndMarkAllInRangeSync(markerLayer, regex, range, options)", ->
    it "populates the marker index with the matching ranges", ->
      buffer = new TextBuffer('abc def\nghi jkl\n')
      layer = buffer.addMarkerLayer()
      markers = buffer.findAndMarkAllInRangeSync(layer, /\w+/g, [[0, 1], [1, 6]], {invalidate: 'inside'})
      expect(markers.map((marker) -> marker.getRange())).toEqual([
        [[0, 1], [0, 3]],
        [[0, 4], [0, 7]],
        [[1, 0], [1, 3]],
        [[1, 4], [1, 6]]
      ])
      expect(markers[0].getInvalidationStrategy()).toBe('inside')
      expect(markers[0].isExclusive()).toBe(true)

      markers = buffer.findAndMarkAllInRangeSync(layer, /abc/g, [[0, 0], [1, 0]], {invalidate: 'touch'})
      expect(markers.map((marker) -> marker.getRange())).toEqual([
        [[0, 0], [0, 3]]
      ])
      expect(markers[0].getInvalidationStrategy()).toBe('touch')
      expect(markers[0].isExclusive()).toBe(false)

  describe "::findWordsWithSubsequence and ::findWordsWithSubsequenceInRange", ->
    it 'resolves with all words matching the given query', (done) ->
      buffer = new TextBuffer('banana bandana ban_ana bandaid band bNa\nbanana')
      buffer.findWordsWithSubsequence('bna', '_', 4).then (results) ->
        expect(JSON.parse(JSON.stringify(results))).toEqual([
          {
            score: 29,
            matchIndices: [0, 1, 2],
            positions: [{row: 0, column: 36}],
            word: "bNa"
          },
          {
            score: 16,
            matchIndices: [0, 2, 4],
            positions: [{row: 0, column: 15}],
            word: "ban_ana"
          },
          {
            score: 12,
            matchIndices: [0, 2, 3],
            positions: [{row: 0, column: 0}, {row: 1, column: 0}],
            word: "banana"
          },
          {
            score: 7,
            matchIndices: [0, 5, 6],
            positions: [{row: 0, column: 7}],
            word: "bandana"
          }
        ])
        done()

    it 'resolves with all words matching the given query and range', (done) ->
      range = {start: {column: 0, row: 0}, end: {column: 22, row: 0}}
      buffer = new TextBuffer('banana bandana ban_ana bandaid band bNa\nbanana')
      buffer.findWordsWithSubsequenceInRange('bna', '_', 3, range).then (results) ->
        expect(JSON.parse(JSON.stringify(results))).toEqual([
          {
            score: 16,
            matchIndices: [0, 2, 4],
            positions: [{row: 0, column: 15}],
            word: "ban_ana"
          },
          {
            score: 12,
            matchIndices: [0, 2, 3],
            positions: [{row: 0, column: 0}],
            word: "banana"
          },
          {
            score: 7,
            matchIndices: [0, 5, 6],
            positions: [{row: 0, column: 7}],
            word: "bandana"
          }
        ])
        done()

  describe "::backwardsScanInRange(range, regex, fn)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = TextBuffer.loadSync(filePath)

    describe "when given a regex with no global flag", ->
      it "calls the iterator with the last match for the given regex in the given range", ->
        matches = []
        ranges = []
        buffer.backwardsScanInRange /cu(rr)ent/, [[4, 0], [6, 44]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 1
        expect(ranges.length).toBe 1

        expect(matches[0][0]).toBe 'current'
        expect(matches[0][1]).toBe 'rr'
        expect(ranges[0]).toEqual [[6, 34], [6, 41]]

    describe "when given a regex with a global flag", ->
      it "calls the iterator with each match for the given regex in the given range, starting with the last match", ->
        matches = []
        ranges = []
        buffer.backwardsScanInRange /cu(rr)ent/g, [[4, 0], [6, 59]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 3
        expect(ranges.length).toBe 3

        expect(matches[0][0]).toBe 'current'
        expect(matches[0][1]).toBe 'rr'
        expect(ranges[0]).toEqual [[6, 34], [6, 41]]

        expect(matches[1][0]).toBe 'current'
        expect(matches[1][1]).toBe 'rr'
        expect(ranges[1]).toEqual [[6, 6], [6, 13]]

        expect(matches[2][0]).toBe 'current'
        expect(matches[2][1]).toBe 'rr'
        expect(ranges[2]).toEqual [[5, 6], [5, 13]]

    describe "when the last regex match starts at the beginning of the range", ->
      it "calls the iterator with the match", ->
        matches = []
        ranges = []
        buffer.scanInRange /quick/g, [[0, 4], [2, 0]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 1
        expect(ranges.length).toBe 1

        expect(matches[0][0]).toBe 'quick'
        expect(ranges[0]).toEqual [[0, 4], [0, 9]]

        matches = []
        ranges = []
        buffer.scanInRange /^/, [[0, 0], [2, 0]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 1
        expect(ranges.length).toBe 1

        expect(matches[0][0]).toBe ""
        expect(ranges[0]).toEqual [[0, 0], [0, 0]]

    describe "when the first regex match exceeds the end of the range", ->
      describe "when the portion of the match within the range also matches the regex", ->
        it "calls the iterator with the truncated match", ->
          matches = []
          ranges = []
          buffer.backwardsScanInRange /cu(r*)/g, [[4, 0], [6, 9]], ({match, range}) ->
            matches.push(match)
            ranges.push(range)

          expect(matches.length).toBe 2
          expect(ranges.length).toBe 2

          expect(matches[0][0]).toBe 'cur'
          expect(matches[0][1]).toBe 'r'
          expect(ranges[0]).toEqual [[6, 6], [6, 9]]

          expect(matches[1][0]).toBe 'curr'
          expect(matches[1][1]).toBe 'rr'
          expect(ranges[1]).toEqual [[5, 6], [5, 10]]

      describe "when the portion of the match within the range does not matches the regex", ->
        it "does not call the iterator with the truncated match", ->
          matches = []
          ranges = []
          buffer.backwardsScanInRange /cu(r*)e/g, [[4, 0], [6, 9]], ({match, range}) ->
            matches.push(match)
            ranges.push(range)

          expect(matches.length).toBe 1
          expect(ranges.length).toBe 1

          expect(matches[0][0]).toBe 'curre'
          expect(matches[0][1]).toBe 'rr'
          expect(ranges[0]).toEqual [[5, 6], [5, 11]]

    describe "when the iterator calls the 'replace' control function with a replacement string", ->
      it "replaces each occurrence of the regex match with the string", ->
        ranges = []
        buffer.backwardsScanInRange /cu(rr)ent/g, [[4, 0], [6, 59]], ({range, replace}) ->
          ranges.push(range)
          replace("foo") unless range.start.isEqual([6, 6])

        expect(ranges[0]).toEqual [[6, 34], [6, 41]]
        expect(ranges[1]).toEqual [[6, 6], [6, 13]]
        expect(ranges[2]).toEqual [[5, 6], [5, 13]]

        expect(buffer.lineForRow(5)).toBe '      foo = items.shift();'
        expect(buffer.lineForRow(6)).toBe '      current < pivot ? left.push(foo) : right.push(current);'

    describe "when the iterator calls the 'stop' control function", ->
      it "stops the traversal", ->
        ranges = []
        buffer.backwardsScanInRange /cu(rr)ent/g, [[4, 0], [6, 59]], ({range, stop}) ->
          ranges.push(range)
          stop() if ranges.length is 2

        expect(ranges.length).toBe 2
        expect(ranges[0]).toEqual [[6, 34], [6, 41]]
        expect(ranges[1]).toEqual [[6, 6], [6, 13]]

    describe "when called with a random range", ->
      it "returns the same results as ::scanInRange, but in the opposite order", ->
        for i in [1...50]
          seed = Date.now()
          random = new Random(seed)

          buffer.backwardsScanChunkSize = random.intBetween(1, 80)

          [startRow, endRow] = [random(buffer.getLineCount()), random(buffer.getLineCount())].sort()
          startColumn = random(buffer.lineForRow(startRow).length)
          endColumn = random(buffer.lineForRow(endRow).length)
          range = [[startRow, startColumn], [endRow, endColumn]]

          regex = [
            /\w/g
            /\w{2}/g
            /\w{3}/g
            /.{5}/g
          ][random(4)]

          if random(2) > 0
            forwardRanges = []
            backwardRanges = []
            forwardMatches = []
            backwardMatches = []

            buffer.scanInRange regex, range, ({range, matchText}) ->
              forwardMatches.push(matchText)
              forwardRanges.push(range)

            buffer.backwardsScanInRange regex, range, ({range, matchText}) ->
              backwardMatches.unshift(matchText)
              backwardRanges.unshift(range)

            expect(backwardRanges).toEqual(forwardRanges, "Seed: #{seed}")
            expect(backwardMatches).toEqual(forwardMatches, "Seed: #{seed}")
          else
            referenceBuffer = new TextBuffer(text: buffer.getText())
            referenceBuffer.scanInRange regex, range, ({matchText, replace}) ->
              replace(matchText + '.')

            buffer.backwardsScanInRange regex, range, ({matchText, replace}) ->
              replace(matchText + '.')

            expect(buffer.getText()).toBe(referenceBuffer.getText(), "Seed: #{seed}")

    it "does not return empty matches at the end of the range", ->
      ranges = []

      buffer.backwardsScanInRange /[ ]*/gm, [[1, 0], [1, 2]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[1, 0], [1, 2]]])

      ranges.length = 0
      buffer.backwardsScanInRange /[ ]*/m, [[0, 29], [1, 2]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[1, 0], [1, 2]]])

      ranges.length = 0
      buffer.backwardsScanInRange /\s*/gm, [[1, 0], [1, 2]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[1, 0], [1, 2]]])

      ranges.length = 0
      buffer.backwardsScanInRange /\s*/m, [[0, 29], [1, 2]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[0, 29], [1, 2]]])

    it "allows empty matches at the end of a range, when the range ends at column 0", ->
      ranges = []
      buffer.backwardsScanInRange /^[ ]*/gm, [[9, 0], [10, 0]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[10, 0], [10, 0]], [[9, 0], [9, 2]]])

      ranges.length = 0
      buffer.backwardsScanInRange /^[ ]*/gm, [[10, 0], [10, 0]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[10, 0], [10, 0]]])

      ranges.length = 0
      buffer.backwardsScanInRange /^\s*/gm, [[9, 0], [10, 0]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[10, 0], [10, 0]], [[9, 0], [9, 2]]])

      ranges.length = 0
      buffer.backwardsScanInRange /^\s*/gm, [[10, 0], [10, 0]], ({range}) -> ranges.push(range)
      expect(ranges).toEqual([[[10, 0], [10, 0]]])

  describe "::characterIndexForPosition(position)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = TextBuffer.loadSync(filePath)

    it "returns the total number of characters that precede the given position", ->
      expect(buffer.characterIndexForPosition([0, 0])).toBe 0
      expect(buffer.characterIndexForPosition([0, 1])).toBe 1
      expect(buffer.characterIndexForPosition([0, 29])).toBe 29
      expect(buffer.characterIndexForPosition([1, 0])).toBe 30
      expect(buffer.characterIndexForPosition([2, 0])).toBe 61
      expect(buffer.characterIndexForPosition([12, 2])).toBe 408
      expect(buffer.characterIndexForPosition([Infinity])).toBe 408

    describe "when the buffer contains crlf line endings", ->
      it "returns the total number of characters that precede the given position", ->
        buffer.setText("line1\r\nline2\nline3\r\nline4")
        expect(buffer.characterIndexForPosition([1])).toBe 7
        expect(buffer.characterIndexForPosition([2])).toBe 13
        expect(buffer.characterIndexForPosition([3])).toBe 20

  describe "::positionForCharacterIndex(position)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = TextBuffer.loadSync(filePath)

    it "returns the position based on character index", ->
      expect(buffer.positionForCharacterIndex(0)).toEqual [0, 0]
      expect(buffer.positionForCharacterIndex(1)).toEqual [0, 1]
      expect(buffer.positionForCharacterIndex(29)).toEqual [0, 29]
      expect(buffer.positionForCharacterIndex(30)).toEqual [1, 0]
      expect(buffer.positionForCharacterIndex(61)).toEqual [2, 0]
      expect(buffer.positionForCharacterIndex(408)).toEqual [12, 2]

    describe "when the buffer contains crlf line endings", ->
      it "returns the position based on character index", ->
        buffer.setText("line1\r\nline2\nline3\r\nline4")
        expect(buffer.positionForCharacterIndex(7)).toEqual [1, 0]
        expect(buffer.positionForCharacterIndex(13)).toEqual [2, 0]
        expect(buffer.positionForCharacterIndex(20)).toEqual [3, 0]

  describe "::isEmpty()", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = TextBuffer.loadSync(filePath)

    it "returns true for an empty buffer", ->
      buffer.setText('')
      expect(buffer.isEmpty()).toBeTruthy()

    it "returns false for a non-empty buffer", ->
      buffer.setText('a')
      expect(buffer.isEmpty()).toBeFalsy()
      buffer.setText('a\nb\nc')
      expect(buffer.isEmpty()).toBeFalsy()
      buffer.setText('\n')
      expect(buffer.isEmpty()).toBeFalsy()

  describe "::onWillChange(callback)", ->
    it "notifies observers before a transaction, an undo or a redo", ->
      changeCount = 0
      expectedText = ''

      buffer = new TextBuffer()
      checkpoint = buffer.createCheckpoint()

      buffer.onWillChange (change) ->
        expect(buffer.getText()).toBe expectedText
        changeCount++

      buffer.append('a')
      expect(changeCount).toBe(1)
      expectedText = 'a'

      buffer.transact ->
        buffer.append('b')
        buffer.append('c')
      expect(changeCount).toBe(2)
      expectedText = 'abc'

      # Empty transactions do not cause onWillChange listeners to be called
      buffer.transact ->
      expect(changeCount).toBe(2)

      buffer.undo()
      expect(changeCount).toBe(3)
      expectedText = 'a'

      buffer.redo()
      expect(changeCount).toBe(4)
      expectedText = 'abc'

      buffer.revertToCheckpoint(checkpoint)
      expect(changeCount).toBe(5)

  describe "::onDidChange(callback)",  ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = TextBuffer.loadSync(filePath)

    it "notifies observers after a transaction, an undo or a redo", ->
      textChanges = []
      buffer.onDidChange ({changes}) -> textChanges.push(changes...)

      buffer.insert([0, 0], "abc")
      buffer.delete([[0, 0], [0, 1]])

      assertChangesEqual(textChanges, [
        {
          oldRange: [[0, 0], [0, 0]],
          newRange: [[0, 0], [0, 3]]
          oldText: "",
          newText: "abc"
        },
        {
          oldRange: [[0, 0], [0, 1]],
          newRange: [[0, 0], [0, 0]],
          oldText: "a",
          newText: ""
        }
      ])

      textChanges = []
      buffer.transact ->
        buffer.insert([1, 0], "v")
        buffer.insert([1, 1], "x")
        buffer.insert([1, 2], "y")
        buffer.insert([2, 3], "zw")
        buffer.delete([[2, 3], [2, 4]])

      assertChangesEqual(textChanges, [
        {
          oldRange: [[1, 0], [1, 0]],
          newRange: [[1, 0], [1, 3]],
          oldText: "",
          newText: "vxy",
        },
        {
          oldRange: [[2, 3], [2, 3]],
          newRange: [[2, 3], [2, 4]],
          oldText: "",
          newText: "w",
        }
      ])

      textChanges = []
      buffer.undo()
      assertChangesEqual(textChanges, [
        {
          oldRange: [[1, 0], [1, 3]],
          newRange: [[1, 0], [1, 0]],
          oldText: "vxy",
          newText: "",
        },
        {
          oldRange: [[2, 3], [2, 4]],
          newRange: [[2, 3], [2, 3]],
          oldText: "w",
          newText: "",
        }
      ])

      textChanges = []
      buffer.redo()
      assertChangesEqual(textChanges, [
        {
          oldRange: [[1, 0], [1, 0]],
          newRange: [[1, 0], [1, 3]],
          oldText: "",
          newText: "vxy",
        },
        {
          oldRange: [[2, 3], [2, 3]],
          newRange: [[2, 3], [2, 4]],
          oldText: "",
          newText: "w",
        }
      ])

      textChanges = []
      buffer.transact ->
        buffer.transact ->
          buffer.insert([0, 0], "j")

      # we emit only one event for nested transactions
      assertChangesEqual(textChanges, [
        {
          oldRange: [[0, 0], [0, 0]],
          newRange: [[0, 0], [0, 1]],
          oldText: "",
          newText: "j",
        }
      ])

    it "doesn't notify observers after an empty transaction", ->
      didChangeTextSpy = jasmine.createSpy()
      buffer.onDidChange(didChangeTextSpy)
      buffer.transact(->)
      expect(didChangeTextSpy).not.toHaveBeenCalled()

    it "doesn't throw an error when clearing the undo stack within a transaction", ->
      buffer.onDidChange(didChangeTextSpy = jasmine.createSpy())
      expect(-> buffer.transact(-> buffer.clearUndoStack())).not.toThrowError()
      expect(didChangeTextSpy).not.toHaveBeenCalled()

  describe "::onDidStopChanging(callback)", ->
    [delay, didStopChangingCallback] = []

    wait = (milliseconds, callback) -> setTimeout(callback, milliseconds)

    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = TextBuffer.loadSync(filePath)
      delay = buffer.stoppedChangingDelay
      didStopChangingCallback = jasmine.createSpy("didStopChangingCallback")
      buffer.onDidStopChanging didStopChangingCallback

    it "notifies observers after a delay passes following changes", (done) ->
      buffer.insert([0, 0], 'a')
      expect(didStopChangingCallback).not.toHaveBeenCalled()

      wait delay / 2, ->
        buffer.transact ->
          buffer.transact ->
            buffer.insert([0, 0], 'b')
            buffer.insert([1, 0], 'c')
            buffer.insert([1, 1], 'd')
        expect(didStopChangingCallback).not.toHaveBeenCalled()

        wait delay / 2, ->
          expect(didStopChangingCallback).not.toHaveBeenCalled()

          wait delay, ->
            expect(didStopChangingCallback).toHaveBeenCalled()
            assertChangesEqual(didStopChangingCallback.calls.mostRecent().args[0].changes, [
              {
                oldRange: [[0, 0], [0, 0]],
                newRange: [[0, 0], [0, 2]],
                oldText: "",
                newText: "ba",
              },
              {
                oldRange: [[1, 0], [1, 0]],
                newRange: [[1, 0], [1, 2]],
                oldText: "",
                newText: "cd",
              }
            ])

            didStopChangingCallback.calls.reset()
            buffer.undo()
            buffer.undo()
            wait delay * 2, ->
              expect(didStopChangingCallback).toHaveBeenCalled()
              assertChangesEqual(didStopChangingCallback.calls.mostRecent().args[0].changes, [
                {
                  oldRange: [[0, 0], [0, 2]],
                  newRange: [[0, 0], [0, 0]],
                  oldText: "ba",
                  newText: "",
                },
                {
                  oldRange: [[1, 0], [1, 2]],
                  newRange: [[1, 0], [1, 0]],
                  oldText: "cd",
                  newText: "",
                },
              ])
              done()

    it "provides the correct changes when the buffer is mutated in the onDidChange callback", (done) ->
      buffer.onDidChange ({changes}) ->
        switch changes[0].newText
          when 'a'
            buffer.insert(changes[0].newRange.end, 'b')
          when 'b'
            buffer.insert(changes[0].newRange.end, 'c')
          when 'c'
            buffer.insert(changes[0].newRange.end, 'd')

      buffer.insert([0, 0], 'a')

      wait delay * 2, ->
        expect(didStopChangingCallback).toHaveBeenCalled()
        assertChangesEqual(didStopChangingCallback.calls.mostRecent().args[0].changes, [
          {
            oldRange: [[0, 0], [0, 0]],
            newRange: [[0, 0], [0, 4]],
            oldText: "",
            newText: "abcd",
          }
        ])
        done()

  describe "::append(text)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = TextBuffer.loadSync(filePath)

    it "adds text to the end of the buffer", ->
      buffer.setText("")
      buffer.append("a")
      expect(buffer.getText()).toBe "a"
      buffer.append("b\nc")
      expect(buffer.getText()).toBe "ab\nc"

  describe "::setLanguageMode", ->
    it "destroys the previous language mode", ->
      buffer = new TextBuffer()

      languageMode1 = {
        alive: true,
        destroy: -> @alive = false
        onDidChangeHighlighting: -> {dispose: ->}
      }

      languageMode2 = {
        alive: true,
        destroy: -> @alive = false
        onDidChangeHighlighting: -> {dispose: ->}
      }

      buffer.setLanguageMode(languageMode1)
      expect(languageMode1.alive).toBe(true)
      expect(languageMode2.alive).toBe(true)

      buffer.setLanguageMode(languageMode2)
      expect(languageMode1.alive).toBe(false)
      expect(languageMode2.alive).toBe(true)

      buffer.destroy()
      expect(languageMode1.alive).toBe(false)
      expect(languageMode2.alive).toBe(false)

    it "notifies ::onDidChangeLanguageMode observers when the language mode changes", ->
      buffer = new TextBuffer()
      expect(buffer.getLanguageMode() instanceof NullLanguageMode).toBe(true)

      events = []
      buffer.onDidChangeLanguageMode (newMode, oldMode) -> events.push({newMode: newMode, oldMode: oldMode})

      languageMode = {
        onDidChangeHighlighting: -> {dispose: ->}
      }

      buffer.setLanguageMode(languageMode)
      expect(buffer.getLanguageMode()).toBe(languageMode)
      expect(events.length).toBe(1)
      expect(events[0].newMode).toBe(languageMode)
      expect(events[0].oldMode instanceof NullLanguageMode).toBe(true)

      buffer.setLanguageMode(null)
      expect(buffer.getLanguageMode() instanceof NullLanguageMode).toBe(true)
      expect(events.length).toBe(2)
      expect(events[1].newMode).toBe(buffer.getLanguageMode())
      expect(events[1].oldMode).toBe(languageMode)

  describe "line ending support", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = TextBuffer.loadSync(filePath)

    describe ".getText()", ->
      it "returns the text with the corrent line endings for each row", ->
        buffer.setText("a\r\nb\nc")
        expect(buffer.getText()).toBe "a\r\nb\nc"
        buffer.setText("a\r\nb\nc\n")
        expect(buffer.getText()).toBe "a\r\nb\nc\n"

    describe "when editing a line", ->
      it "preserves the existing line ending", ->
        buffer.setText("a\r\nb\nc")
        buffer.insert([0, 1], "1")
        expect(buffer.getText()).toBe "a1\r\nb\nc"

    describe "when inserting text with multiple lines", ->
      describe "when the current line has a line ending", ->
        it "uses the same line ending as the line where the text is inserted", ->
          buffer.setText("a\r\n")
          buffer.insert([0, 1], "hello\n1\n\n2")
          expect(buffer.getText()).toBe "ahello\r\n1\r\n\r\n2\r\n"

      describe "when the current line has no line ending (because it's the last line of the buffer)", ->
        describe "when the buffer contains only a single line", ->
          it "honors the line endings in the inserted text", ->
            buffer.setText("initialtext")
            buffer.append("hello\n1\r\n2\n")
            expect(buffer.getText()).toBe "initialtexthello\n1\r\n2\n"

        describe "when the buffer contains a preceding line", ->
          it "uses the line ending of the preceding line", ->
            buffer.setText("\ninitialtext")
            buffer.append("hello\n1\r\n2\n")
            expect(buffer.getText()).toBe "\ninitialtexthello\n1\n2\n"

    describe "::setPreferredLineEnding(lineEnding)", ->
      it "uses the given line ending when normalizing, rather than inferring one from the surrounding text", ->
        buffer = new TextBuffer(text: "a \r\n")

        expect(buffer.getPreferredLineEnding()).toBe null
        buffer.append(" b \n")
        expect(buffer.getText()).toBe "a \r\n b \r\n"

        buffer.setPreferredLineEnding("\n")
        expect(buffer.getPreferredLineEnding()).toBe "\n"
        buffer.append(" c \n")
        expect(buffer.getText()).toBe "a \r\n b \r\n c \n"

        buffer.setPreferredLineEnding(null)
        buffer.append(" d \r\n")
        expect(buffer.getText()).toBe "a \r\n b \r\n c \n d \n"

      it "persists across serialization and deserialization", (done) ->
        bufferA = new TextBuffer
        bufferA.setPreferredLineEnding("\r\n")

        TextBuffer.deserialize(bufferA.serialize()).then (bufferB) ->
          expect(bufferB.getPreferredLineEnding()).toBe "\r\n"
          done()

assertChangesEqual = (actualChanges, expectedChanges) ->
  expect(actualChanges.length).toBe(expectedChanges.length)
  for actualChange, i in actualChanges
    expectedChange = expectedChanges[i]
    expect(actualChange.oldRange).toEqual(expectedChange.oldRange)
    expect(actualChange.newRange).toEqual(expectedChange.newRange)
    expect(actualChange.oldText).toEqual(expectedChange.oldText)
    expect(actualChange.newText).toEqual(expectedChange.newText)
