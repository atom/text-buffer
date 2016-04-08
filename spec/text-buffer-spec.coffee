fs = require 'fs-plus'
{join} = require 'path'
temp = require 'temp'
{File} = require 'pathwatcher'
Random = require 'random-seed'
Point = require '../src/point'
Range = require '../src/range'
TextBuffer = require '../src/text-buffer'
SampleText = fs.readFileSync(join(__dirname, 'fixtures', 'sample.js'), 'utf8')

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
      text = "hello\nworld\r\nhow are you doing?\rlast"
      buffer = new TextBuffer(text)
      expect(buffer.getLineCount()).toBe 4
      expect(buffer.getText()).toBe text
      expect(buffer.lineForRow(0)).toBe 'hello'
      expect(buffer.lineEndingForRow(0)).toBe '\n'
      expect(buffer.lineForRow(1)).toBe 'world'
      expect(buffer.lineEndingForRow(1)).toBe '\r\n'
      expect(buffer.lineForRow(2)).toBe 'how are you doing?'
      expect(buffer.lineEndingForRow(2)).toBe '\r'
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

    describe "when a file path is given", ->
      [filePath] = []

      beforeEach (done) ->
        filePath = require.resolve('./fixtures/sample.js')
        buffer = new TextBuffer({filePath, load: false})
        buffer.load().then ->
          done()

      afterEach ->
        buffer?.destroy()

      describe "when a file exists for the path", ->
        it "loads the contents of that file", ->
          expect(buffer.getText()).toBe fs.readFileSync(filePath, 'utf8')

        it "does not allow the initial state of the buffer to be undone", ->
          buffer.undo()
          expect(buffer.getText()).toBe fs.readFileSync(filePath, 'utf8')

      describe "when no file exists for the path", ->
        it "is not modified and is initially empty", (done) ->
          filePath = "does-not-exist.txt"
          expect(fs.existsSync(filePath)).toBeFalsy()
          buffer = new TextBuffer({filePath, load: false})
          buffer.load().then ->
            expect(buffer.isModified()).not.toBeTruthy()
            expect(buffer.getText()).toBe ''
            done()

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

    it "notifies ::onWillChange observers with the relevant details before a change", ->
      changes = []
      buffer.onWillChange (change) ->
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"
        changes.push(change)

      buffer.setTextInRange([[0, 2], [2, 3]], "y there\r\ncat\nwhat", normalizeLineEndings: false)
      expect(changes).toEqual [{
        oldRange: [[0, 2], [2, 3]]
        newRange: [[0, 2], [2, 4]]
        oldText: "llo\nworld\r\nhow"
        newText: "y there\r\ncat\nwhat"
      }]

    it "notifies ::onDidChange observers with the relevant details after a change", ->
      changes = []
      buffer.onDidChange (change) -> changes.push(change)
      buffer.setTextInRange([[0, 2], [2, 3]], "y there\r\ncat\nwhat", normalizeLineEndings: false)
      expect(changes).toEqual [{
        oldRange: [[0, 2], [2, 3]]
        newRange: [[0, 2], [2, 4]]
        oldText: "llo\nworld\r\nhow"
        newText: "y there\r\ncat\nwhat"
      }]

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
        expect(buffer.lineForRow(0)).toBe "hellow"

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

  describe "checkpoints", ->
    beforeEach ->
      buffer = new TextBuffer

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
        buffer.append("one\n")
        checkpoint = buffer.createCheckpoint()
        buffer.append("two\n")
        buffer.transact ->
          buffer.append("three\n")
          buffer.append("four")

        historyLayer = buffer.addMarkerLayer(maintainHistory: true)
        historyLayer.markRange([[0, 1], [2, 3]], a: 'b')
        result = buffer.groupChangesSinceCheckpoint(checkpoint)

        expect(result).toBeTruthy()
        expect(buffer.getText()).toBe """
          one
          two
          three
          four
        """

        buffer.undo()
        expect(buffer.getText()).toBe("one\n")

        buffer.redo()
        expect(buffer.getText()).toBe """
          one
          two
          three
          four
        """

        [marker] = historyLayer.getMarkers()
        expect(marker.getRange()).toEqual [[0, 1], [2, 3]]
        expect(marker.getProperties()).toEqual {a: 'b'}

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
      bufferB = TextBuffer.deserialize(state)

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

    it "serializes / deserializes the buffer's persistent custom marker layers", ->
      bufferA = new TextBuffer("abcdefghijklmnopqrstuvwxyz")

      layer1A = bufferA.addMarkerLayer()
      layer2A = bufferA.addMarkerLayer(persistent: true)

      layer1A.markRange([[0, 1], [0, 2]])
      layer1A.markRange([[0, 3], [0, 4]])

      layer2A.markRange([[0, 5], [0, 6]])
      layer2A.markRange([[0, 7], [0, 8]])

      bufferB = TextBuffer.deserialize(JSON.parse(JSON.stringify(bufferA.serialize())))
      layer1B = bufferB.getMarkerLayer(layer1A.id)
      layer2B = bufferB.getMarkerLayer(layer2A.id)
      expect(layer2B.persistent).toBe true

      expect(layer1B).toBe undefined
      expectSameMarkers(layer2A, layer2B)

    it "doesn't serialize the default marker layer", ->
      bufferA = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      markerLayerA = bufferA.getDefaultMarkerLayer()
      marker1A = bufferA.markRange([[0, 1], [1, 2]], foo: 1)

      bufferB = TextBuffer.deserialize(bufferA.serialize())
      markerLayerB = bufferB.getDefaultMarkerLayer()
      expect(markerLayerA.id).not.toBe(markerLayerB.id)
      expect(bufferB.getMarker(marker1A.id)).toBeUndefined()

    it "doesn't attempt to serialize snapshots for destroyed marker layers", ->
      buffer = new TextBuffer(text: "abc")
      markerLayer = buffer.addMarkerLayer(maintainHistory: true, persistent: true)
      markerLayer.markPosition([0, 3])
      buffer.insert([0, 0], 'x')
      markerLayer.destroy()

      expect(-> buffer.serialize()).not.toThrowError()

    it "doesn't remember marker layers when calling serialize with {markerLayers: false}", ->
      bufferA = new TextBuffer(text: "world")
      layerA = bufferA.addMarkerLayer(maintainHistory: true)
      markerA = layerA.markPosition([0, 3])
      markerB = null
      bufferA.transact ->
        bufferA.insert([0, 0], 'hello ')
        markerB = layerA.markPosition([0, 5])
      bufferA.undo()

      bufferB = TextBuffer.deserialize(bufferA.serialize({markerLayers: false}))
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

    it "serializes / deserializes the buffer's unique identifier", ->
      bufferA = new TextBuffer()
      bufferB = TextBuffer.deserialize(JSON.parse(JSON.stringify(bufferA.serialize())))

      expect(bufferB.getId()).toEqual(bufferA.getId())

    it "doesn't deserialize a state that was serialized with a different buffer version", ->
      bufferA = new TextBuffer()
      serializedBuffer = JSON.parse(JSON.stringify(bufferA.serialize()))
      serializedBuffer.version = 123456789

      expect(TextBuffer.deserialize(serializedBuffer)).toBeUndefined()

    describe "when the buffer has a path", ->
      [filePath, buffer2] = []

      beforeEach (done) ->
        filePath = temp.openSync('atom').path
        fs.writeFileSync(filePath, "words")
        buffer = new TextBuffer({filePath, load: false})
        buffer.load().then ->
          done()

      afterEach ->
        buffer2?.destroy()

      describe "when the serialized buffer had no unsaved changes", ->
        [buffer2, buffer2ModifiedEvents] = []
        beforeEach (done) ->
          buffer.append("!")
          buffer.save()
          expect(buffer.isModified()).toBeFalsy()
          params = buffer.serialize()
          params.load = false
          buffer2 = TextBuffer.deserialize(params)
          buffer2ModifiedEvents = []
          buffer2.onDidChangeModified (value) -> buffer2ModifiedEvents.push(value)
          buffer2.load().then ->
            done()

        it "loads the current contents of the file at the serialized path", (done) ->
          expect(buffer2.isModified()).toBeFalsy()
          expect(buffer2ModifiedEvents).toEqual [false]
          expect(buffer2.getPath()).toBe(filePath)
          expect(buffer2.getText()).toBe('words!')

          buffer.undo()
          buffer2.undo()
          setTimeout(->
            expect(buffer2.getText()).toBe('words')
            expect(buffer2ModifiedEvents).toEqual [false, true]
            done()
          , buffer.stoppedChangingDelay)

      describe "when the serialized buffer had unsaved changes", ->
        describe "when the disk contents were changed since serialization", ->
          it "loads the disk contents instead of the previous unsaved state", (done) ->
            buffer.setText("BUFFER CHANGE")
            fs.writeFileSync(filePath, "DISK CHANGE")

            params = buffer.serialize()
            params.load = false
            buffer2 = TextBuffer.deserialize(params)
            buffer2.load().then ->
              expect(buffer2.getPath()).toBe(buffer.getPath())
              expect(buffer2.getText()).toBe("DISK CHANGE")
              expect(buffer2.isModified()).toBeFalsy()
              done()

        describe "when the disk contents are the same since serialization", ->
          [previousText] = []
          beforeEach (done) ->
            previousText = buffer.getText()
            buffer.setText("abc")
            buffer.append("d")

            buffer2 = TextBuffer.deserialize(buffer.serialize())
            buffer2.load().then ->
              done()

          it "restores the previous unsaved state of the buffer", ->
            expect(buffer2.getPath()).toBe(buffer.getPath())
            expect(buffer2.getText()).toBe(buffer.getText())
            expect(buffer2.isModified()).toBeTruthy()

            buffer.undo()
            buffer2.undo()
            expect(buffer2.getText()).toBe(buffer.getText())

            buffer2.setText(previousText)
            expect(buffer2.isModified()).toBeFalsy()

      describe "when the serialized buffer was unsaved and had no path", ->
        it "restores the previous unsaved state of the buffer", ->
          buffer.destroy()

          buffer = new TextBuffer()
          buffer.setText("abc")

          buffer2 = TextBuffer.deserialize(buffer.serialize())
          expect(buffer2.getPath()).toBeUndefined()
          expect(buffer2.getText()).toBe("abc")

  describe "::getRange()", ->
    it "returns the range of the entire buffer text", ->
      buffer = new TextBuffer("abc\ndef\nghi")
      expect(buffer.getRange()).toEqual [[0, 0], [2, 3]]

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

    beforeEach (done) ->
      tempDir = fs.realpathSync(temp.mkdirSync('text-buffer'))
      filePath = join(tempDir, "manipulate-me")
      newPath = "#{filePath}-i-moved"
      fs.writeFileSync(filePath, "")
      bufferToChange = new TextBuffer({filePath, load: false})
      bufferToChange.load().then ->
        done()

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
    [filePath, bufferToChange, eventHandler] = []

    beforeEach (done) ->
      tempDir = fs.realpathSync(temp.mkdirSync('text-buffer'))
      filePath = join(tempDir , "manipulate-me")
      fs.writeFileSync(filePath, "")
      bufferToChange = new TextBuffer({filePath, load: false})
      eventHandler = jasmine.createSpy('eventHandler')
      bufferToChange.onWillThrowWatchError eventHandler
      bufferToChange.load().then ->
        done()

    afterEach ->
      bufferToChange.destroy()
      fs.removeSync(filePath)

    it "notifies observers when the file has a watch error", ->
      bufferToChange.file.emitter.emit 'will-throw-watch-error', 'arg'
      expect(eventHandler).toHaveBeenCalledWith 'arg'

  describe "when the buffer's on-disk contents change", ->
    filePath = null

    beforeEach (done) ->
      filePath = temp.openSync('atom').path
      fs.writeFileSync(filePath, "first")
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        done()

    afterEach ->
      buffer?.destroy()

    it "does not notify ::onDidChange observers when the file is written via TextBuffer::save", (done) ->
      buffer.insert([0,0], "HELLO!")
      changeHandler = jasmine.createSpy("buffer changed")
      buffer.onDidChange changeHandler
      buffer.save()
      setTimeout(->
        expect(changeHandler).not.toHaveBeenCalled()
        done()
      , 30)

    describe "when the buffer is in an unmodified state before the file is modified on disk", ->
      [event1, event2] = []
      beforeEach (done) ->
        calls = 0
        buffer.onDidChange (args) ->
          calls = calls + 1
          event1 = args if calls is 1
          event2 = args if calls is 2
          done() if calls > 1
        fs.writeFileSync(filePath, "second")
        expect(calls).toBe(0)

      it "changes the in-memory contents of the buffer to match the new disk contents and notifies ::onDidChange observers", ->
        expect(event1.oldRange).toEqual [[0, 0], [0, 5]]
        expect(event1.newRange).toEqual [[0, 0], [0, 0]]
        expect(event1.oldText).toBe "first"
        expect(event1.newText).toBe ""

        expect(event2.oldRange).toEqual [[0, 0], [0, 0]]
        expect(event2.newRange).toEqual [[0, 0], [0, 6]]
        expect(event2.oldText).toBe ""
        expect(event2.newText).toBe "second"

        expect(buffer.isModified()).toBeFalsy()

    describe "when the buffer's memory contents differ from the *previous* disk contents", ->
      it "leaves the buffer in a modified state (does not update its memory contents)", (done) ->
        calls = 0
        buffer.file.onDidChange ->
          calls = calls + 1
          expect(buffer.isModified()).toBeTruthy()
          done() if calls > 1

        expect(calls).toBe 0
        buffer.insert([0, 0], "a change")
        fs.writeFileSync(filePath, "second")

      it "notifies ::onDidConflict observers", (done) ->
        buffer.setText("a change")
        buffer.save()
        buffer.insert([0, 0], "a second change")
        called = false
        buffer.onDidConflict ->
          called = true
          done()

        expect(called).toBe false
        fs.writeFileSync(filePath, "a disk change")

  describe "when the buffer's file is deleted (via another process)", ->
    [filePath, bufferToDelete] = []

    beforeEach (done) ->
      tempDir = fs.realpathSync(temp.mkdirSync())
      filePath = join(tempDir, 'atom-file-to-delete.txt')
      fs.writeFileSync(filePath, 'delete me')
      bufferToDelete = new TextBuffer({filePath, load: false})
      filePath = bufferToDelete.getPath() # symlinks may have been converted
      expect(bufferToDelete.getPath()).toBe filePath
      bufferToDelete.load().then ->
        done()

    afterEach ->
      bufferToDelete?.destroy()

    describe "when the file is modified", ->
      beforeEach (done) ->
        bufferToDelete.setText("I WAS MODIFIED")
        expect(bufferToDelete.isModified()).toBeTruthy()
        bufferToDelete.file.onDidDelete ->
          done()
        fs.removeSync(filePath)

      it "retains its path and reports the buffer as modified", ->
        expect(bufferToDelete.getPath()).toBe filePath
        expect(bufferToDelete.isModified()).toBeTruthy()

    describe "when the file is not modified", ->
      beforeEach (done) ->
        expect(bufferToDelete.isModified()).toBeFalsy()
        bufferToDelete.file.onDidDelete ->
          done()
        fs.removeSync(filePath)

      it "retains its path and reports the buffer as not modified", ->
        # FIXME: This doesn't pass on Linux
        return if process.platform is 'linux'

        expect(bufferToDelete.getPath()).toBe filePath
        expect(bufferToDelete.isModified()).toBeFalsy()


    describe "when the file is deleted", ->
      it "notifies all onDidDelete listeners ", (done) ->
        bufferToDelete.onDidDelete ->
          done()
        fs.removeSync(filePath)

    it "resumes watching of the file when it is re-saved", (done) ->
      bufferToDelete.save()
      expect(fs.existsSync(bufferToDelete.getPath())).toBeTruthy()
      expect(bufferToDelete.isInConflict()).toBeFalsy()

      fs.writeFileSync(filePath, 'moo')

      bufferToDelete.onDidChange ->
        done()

  describe "modified status", ->
    [filePath, modifiedHandler, doneFunc] = []

    beforeEach (done) ->
      tempDir = temp.mkdirSync()
      filePath = join(tempDir, 'atom-tmp-file')
      fs.writeFileSync(filePath, '')
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        done()

    afterEach ->
      buffer?.destroy()
      modifiedHandler = null
      doneFunc = null

    describe "after the user changes buffer", ->
      beforeEach (done) ->
        doneFunc = done
        modifiedHandler = jasmine.createSpy("modifiedHandler").and.callFake ->
          doneFunc()
        buffer.onDidChangeModified modifiedHandler

        expect(buffer.isModified()).toBeFalsy()
        buffer.insert([0,0], "hi")
        expect(buffer.isModified()).toBe true

      beforeEach (done) ->
        expect(modifiedHandler).toHaveBeenCalledWith(true)

        modifiedHandler.calls.reset()
        buffer.insert([0,2], "ho")
        setTimeout(->
          expect(modifiedHandler).not.toHaveBeenCalled()
          done()
        , buffer.stoppedChangingDelay * 2)

      it "reports the modified status changing to true or false", (done) ->
        modifiedHandler.calls.reset()
        doneFunc = ->
          expect(modifiedHandler).toHaveBeenCalledWith(false)
          done()
        buffer.undo()
        buffer.undo()

    describe "after a modified buffer is saved", ->
      beforeEach (done) ->
        doneFunc = done
        modifiedHandler = jasmine.createSpy("modifiedHandler").and.callFake ->
          doneFunc()
        buffer.onDidChangeModified modifiedHandler
        buffer.insert([0,0], "hi")

      it "reports the modified status changing to false", (done) ->
        expect(buffer.isModified()).toBe true

        modifiedHandler.calls.reset()
        buffer.save()

        expect(modifiedHandler).toHaveBeenCalledWith(false)
        expect(buffer.isModified()).toBe false
        modifiedHandler.calls.reset()
        doneFunc = ->
          expect(modifiedHandler).toHaveBeenCalledWith(true)
          expect(buffer.isModified()).toBe true
          done()
        buffer.insert([0, 0], 'x')

    describe "after a modified buffer is reloaded", ->
      beforeEach (done) ->
        doneFunc = done
        modifiedHandler = jasmine.createSpy("modifiedHandler").and.callFake ->
          doneFunc()
        buffer.onDidChangeModified modifiedHandler
        buffer.insert([0,0], "hi")

      it "reports the modified status changing to false after a modified buffer is reloaded", ->
        expect(buffer.isModified()).toBe true

        modifiedHandler.calls.reset()
        buffer.reload()

        expect(modifiedHandler).toHaveBeenCalledWith(false)
        expect(buffer.isModified()).toBe false

        modifiedHandler.calls.reset()
        doneFunc = ->
          expect(modifiedHandler).toHaveBeenCalledWith(true)
          expect(buffer.isModified()).toBe true
          done()
        buffer.insert([0, 0], 'x')

    describe "after a buffer to a non-existent file is saved", ->
      beforeEach (done) ->
        buffer.destroy()
        tempDir = temp.mkdirSync()
        filePath = join(tempDir, 'atom-file')
        expect(fs.existsSync(filePath)).toBeFalsy()

        buffer = new TextBuffer({filePath, load: false})
        buffer.load().then ->
          done()

      beforeEach (done) ->
        doneFunc = done
        modifiedHandler = jasmine.createSpy("modifiedHandler").and.callFake ->
          doneFunc()
        buffer.onDidChangeModified modifiedHandler
        buffer.insert([0,0], "hi")

      it "reports the modified status changing to false", (done) ->
        expect(buffer.isModified()).toBe true

        modifiedHandler.calls.reset()
        buffer.save()

        expect(fs.existsSync(filePath)).toBeTruthy()
        expect(modifiedHandler).toHaveBeenCalledWith(false)
        expect(buffer.isModified()).toBe false

        modifiedHandler.calls.reset()
        doneFunc = ->
          expect(modifiedHandler).toHaveBeenCalledWith(true)
          expect(buffer.isModified()).toBe true
          done()
        buffer.insert([0, 0], 'x')

    it "returns false for an empty buffer with no path", ->
      buffer.destroy()
      buffer = new TextBuffer()
      expect(buffer.isModified()).toBeFalsy()
      buffer.append('hello')
      expect(buffer.isModified()).toBeTruthy()

    it "returns true for a non-empty buffer with no path", ->
      buffer.destroy()
      buffer = new TextBuffer({text: 'something'})
      expect(buffer.isModified()).toBeTruthy()
      buffer.append('a')
      expect(buffer.isModified()).toBeTruthy()
      buffer.setText('')
      expect(buffer.isModified()).toBeFalsy()

    it "returns false until the buffer is fully loaded", (done) ->
      buffer.destroy()
      buffer = new TextBuffer({filePath, load: false})
      expect(buffer.isModified()).toBeFalsy()
      buffer.load().then ->
        expect(buffer.isModified()).toBeFalsy()
        done()

  describe "::getLines()", ->
    it "returns an array of lines in the text contents", (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        expect(buffer.getLines().length).toBe fileContents.split("\n").length
        expect(buffer.getLines().join('\n')).toBe fileContents
        done()

  describe "::change(range, string)", ->
    changeHandler = null

    beforeEach (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
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
    beforeEach (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        done()

    describe "when the buffer contains newlines", ->
      it "changes the entire contents of the buffer and emits a change event", ->
        lastRow = buffer.getLastRow()
        expectedPreRange = [[0,0], [lastRow, buffer.lineForRow(lastRow).length]]
        changeHandler = jasmine.createSpy('changeHandler')
        buffer.onDidChange changeHandler

        newText = "I know you are.\rBut what am I?"
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
        expectedPreRange = [[0,0], [lastRow, buffer.lineForRow(lastRow).length]]
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

    describe "when the buffer contains carriage returns for newlines", ->
      it "changes the entire contents of the buffer", ->
        buffer = new TextBuffer("first\rlast")
        lastRow = buffer.getLastRow()
        expectedPreRange = [[0,0], [lastRow, buffer.lineForRow(lastRow).length]]
        changeHandler = jasmine.createSpy('changeHandler')
        buffer.onDidChange changeHandler

        newText = "new first\rnew last"
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
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        done()

    it "can change the entire contents of the buffer when there are no newlines", ->
      buffer.setText('BUFFER CHANGE')
      newText = 'DISK CHANGE'
      buffer.setTextViaDiff(newText)
      expect(buffer.getText()).toBe newText

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

    describe "when the buffer contains carriage returns for newlines", ->
      it "can replace the contents of the buffer", ->
        originalText = "beginning\rmiddle\rlast"
        newText = "new beginning\rnew last"
        buffer = new TextBuffer(originalText)
        expect(buffer.getText()).toBe originalText

        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

        buffer.setTextViaDiff(originalText)
        expect(buffer.getText()).toBe originalText

  describe "::save()", ->
    saveBuffer = null

    afterEach ->
      saveBuffer?.destroy()

    describe "when the buffer has a path", ->
      filePath = null

      beforeEach (done) ->
        tempDir = temp.mkdirSync()
        filePath = join(tempDir, 'temp.txt')
        fs.writeFileSync(filePath, "")
        saveBuffer = new TextBuffer({filePath, load: false})
        saveBuffer.load().then ->
          saveBuffer.setText("blah")
          done()

      it "saves the contents of the buffer to the path", ->
        saveBuffer.setText 'Buffer contents!'
        saveBuffer.save()
        expect(fs.readFileSync(filePath, 'utf8')).toEqual 'Buffer contents!'

      it "notifies ::onWillSave and ::onDidSave observers around the call to File::writeSync", ->
        events = []
        willSave1 = (event) -> events.push(['will-save-1', event])
        willSave2 = (event) -> events.push(['will-save-2', event])
        didSave1 = (event) -> events.push(['did-save-1', event])
        didSave2 = (event) -> events.push(['did-save-2', event])

        saveBuffer.onWillSave willSave1
        saveBuffer.onWillSave willSave2
        spyOn(File.prototype, 'writeSync').and.callFake -> events.push 'File::writeSync'
        saveBuffer.onDidSave didSave1
        saveBuffer.onDidSave didSave2

        saveBuffer.save()
        path = saveBuffer.getPath()
        expect(events).toEqual [
          ['will-save-1', {path}]
          ['will-save-2', {path}]
          'File::writeSync'
          ['did-save-1', {path}]
          ['did-save-2', {path}]
        ]

      it "notifies ::onWillReload and ::onDidReload observers when reloaded", ->
        events = []

        saveBuffer.onWillReload -> events.push 'will-reload'
        saveBuffer.onDidReload -> events.push 'did-reload'
        saveBuffer.reload()
        expect(events).toEqual ['will-reload', 'did-reload']

      describe "when a conflict is created", ->
        beforeEach (done) ->
          saveBuffer.setText('a')
          saveBuffer.save()
          saveBuffer.setText('ab')
          saveBuffer.onDidConflict ->
            done()
          fs.writeFileSync(saveBuffer.getPath(), 'c')

        it "no longer reports being in conflict when the buffer is saved again", ->
          expect(saveBuffer.isInConflict()).toBe true
          saveBuffer.save()
          expect(saveBuffer.isInConflict()).toBe false

    describe "when the buffer has no path", ->
      it "throws an exception", (done) ->
        saveBuffer = new TextBuffer({load: false})
        saveBuffer.load().then ->
          saveBuffer.setText "hi"
          expect(-> saveBuffer.save()).toThrowError()
          done()

  describe "::reload()", ->
    it "reloads current text from disk and clears any conflicts", (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        buffer.setText("abc")
        buffer.conflict = true

        buffer.reload()
        expect(buffer.isModified()).toBeFalsy()
        expect(buffer.isInConflict()).toBeFalsy()
        expect(buffer.getText()).toBe(fileContents)
        done()

    it "does not throw if the buffer has no backing file", ->
      buffer = new TextBuffer()
      buffer.reload()

  describe "::saveAs(path, {backup})", ->
    [filePath, saveAsBuffer, tempDir] = []

    beforeEach ->
      tempDir = temp.mkdirSync()

    afterEach ->
      saveAsBuffer?.destroy()

    it "saves the contents of the buffer to the path", ->
      filePath = join(tempDir, 'temp.txt')
      fs.removeSync(filePath)

      saveAsBuffer = new TextBuffer()
      eventHandler = jasmine.createSpy('eventHandler')
      saveAsBuffer.onDidChangePath eventHandler

      saveAsBuffer.setText 'Buffer contents!'
      saveAsBuffer.saveAs(filePath)
      expect(fs.readFileSync(filePath, 'utf8')).toEqual 'Buffer contents!'

      expect(eventHandler).toHaveBeenCalledWith(filePath)

    describe "when the path is changed", ->
      [changeHandler, originalPath, newPath, saveAsBuffer, doneFunc] = []
      beforeEach (done) ->
        changeHandler = null
        originalPath = join(tempDir, 'original.txt')
        newPath = join(tempDir, 'new.txt')
        fs.writeFileSync(originalPath, "")

        saveAsBuffer = new TextBuffer({filePath: originalPath, load: false})
        saveAsBuffer.load().then ->
          done()

      beforeEach (done) ->
        doneFunc = ->
          # No-op

        changeHandler = jasmine.createSpy('changeHandler').and.callFake ->
          doneFunc()
        saveAsBuffer.onDidChange changeHandler
        saveAsBuffer.saveAs(newPath)
        expect(changeHandler).not.toHaveBeenCalled()

        fs.writeFileSync(originalPath, "should not trigger buffer event")
        setTimeout(->
          expect(changeHandler).not.toHaveBeenCalled()
          done()
        , 20)

      it "stops listening to events on previous path and begins listening to events on new path", (done) ->
        doneFunc = ->
          expect(changeHandler).toHaveBeenCalled()
          done()
        fs.writeFileSync(newPath, "should trigger buffer event")

    describe "if the 'backup' option is true", ->
      [backupFilePath, saveAsBuffer] = []

      beforeEach ->
        tempDir = temp.mkdirSync()
        filePath = join(tempDir, 'temp.txt')
        saveAsBuffer = new TextBuffer()
        saveAsBuffer.setText 'Buffer contents'
        backupFilePath = filePath + '~'
        fs.removeSync(backupFilePath) if fs.existsSync(backupFilePath)

      describe "if there is an existing file at the specified path", ->
        beforeEach ->
          fs.writeFileSync(filePath, 'File contents')

        describe "if the file is written cleanly", ->
          it "deletes the backup copy after writing", ->
            saveAsBuffer.saveAs(filePath, backup: true)
            expect(fs.readFileSync(filePath, 'utf8')).toBe 'Buffer contents'
            expect(fs.existsSync(backupFilePath)).toBe false

        describe "if an exception is thrown while writing to the file", ->
          it "restores the file's original contents from the backup copy, preserves the backup copy just in case, and re-throws the exception", ->
            saveAsBuffer.setPath(filePath)
            originalWriteSync = saveAsBuffer.file.writeSync
            saveAsBuffer.file.writeSync = (args...) ->
              originalWriteSync.apply(saveAsBuffer.file, args)
              throw new Error('Something broke')

            expect(-> saveAsBuffer.saveAs(filePath, backup: true)).toThrowError 'Something broke'

            expect(fs.readFileSync(filePath, 'utf8')).toBe 'File contents'
            expect(fs.existsSync(backupFilePath)).toBe true

        describe "if a file already exists at the default backup path", ->
          it "chooses a different backup file name to avoid overwriting the existing file", ->
            alternateBackupFilePath = backupFilePath + '~'
            fs.removeSync(alternateBackupFilePath) if fs.existsSync(alternateBackupFilePath)

            fs.writeFileSync(backupFilePath, 'Contents of file at default backup path')

            saveAsBuffer.saveAs(filePath, backup: true)
            expect(fs.readFileSync(filePath, 'utf8')).toBe 'Buffer contents'
            expect(fs.readFileSync(backupFilePath, 'utf8')).toBe 'Contents of file at default backup path'
            expect(fs.existsSync(backupFilePath)).toBe true
            expect(fs.existsSync(alternateBackupFilePath)).toBe false

      describe "if no file exists at the path", ->
        it "does not make a backup before writing", ->
          fs.removeSync(filePath) if fs.existsSync(filePath)
          expect(fs.existsSync(filePath)).toBe false
          expect(fs.existsSync(backupFilePath)).toBe false
          saveAsBuffer.saveAs(filePath, backup: true)
          expect(fs.existsSync(backupFilePath)).toBe false

  describe "::getTextInRange(range)", ->
    beforeEach (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        done()

    describe "when range is empty", ->
      it "returns an empty string", ->
        range = [[1,1], [1,1]]
        expect(buffer.getTextInRange(range)).toBe ""

    describe "when range spans one line", ->
      it "returns characters in range", ->
        range = [[2,8], [2,13]]
        expect(buffer.getTextInRange(range)).toBe "items"

        lineLength = buffer.lineForRow(2).length
        range = [[2,0], [2,lineLength]]
        expect(buffer.getTextInRange(range)).toBe "    if (items.length <= 1) return items;"

    describe "when range spans multiple lines", ->
      it "returns characters in range (including newlines)", ->
        lineLength = buffer.lineForRow(2).length
        range = [[2,0], [3,0]]
        expect(buffer.getTextInRange(range)).toBe "    if (items.length <= 1) return items;\n"

        lineLength = buffer.lineForRow(2).length
        range = [[2,10], [4,10]]
        expect(buffer.getTextInRange(range)).toBe "ems.length <= 1) return items;\n    var pivot = items.shift(), current, left = [], right = [];\n    while("

    describe "when the range starts before the start of the buffer", ->
      it "clips the range to the start of the buffer", ->
        expect(buffer.getTextInRange([[-Infinity, -Infinity], [0, Infinity]])).toBe buffer.lineForRow(0)

    describe "when the range ends after the end of the buffer", ->
      it "clips the range to the end of the buffer", ->
        expect(buffer.getTextInRange([[12], [13, Infinity]])).toBe buffer.lineForRow(12)

  describe "::scan(regex, fn)", ->
    beforeEach ->
      buffer = new TextBuffer(filePath: require.resolve('./fixtures/sample.js'))
      buffer.loadSync()

    it "calls the given function with the information about each match", ->
      matches = []
      buffer.scan /current/g, (match) -> matches.push(match)
      expect(matches.length).toBe 5

      expect(matches[0].matchText).toBe 'current'
      expect(matches[0].range).toEqual [[3, 31], [3, 38]]
      expect(matches[0].lineText).toBe '    var pivot = items.shift(), current, left = [], right = [];'
      expect(matches[0].lineTextOffset).toBe 0

      expect(matches[1].matchText).toBe 'current'
      expect(matches[1].range).toEqual [[5, 6], [5, 13]]
      expect(matches[1].lineText).toBe '      current = items.shift();'
      expect(matches[1].lineTextOffset).toBe 0

  describe "::backwardsScan(regex, fn)", ->
    beforeEach ->
      buffer = new TextBuffer(filePath: require.resolve('./fixtures/sample.js'))
      buffer.loadSync()

    it "calls the given function with the information about each match in backwards order", ->
      matches = []
      buffer.backwardsScan /current/g, (match) -> matches.push(match)
      expect(matches.length).toBe 5

      expect(matches[0].matchText).toBe 'current'
      expect(matches[0].range).toEqual [[6, 56], [6, 63]]
      expect(matches[0].lineText).toBe '      current < pivot ? left.push(current) : right.push(current);'
      expect(matches[0].lineTextOffset).toBe 0

      expect(matches[1].matchText).toBe 'current'
      expect(matches[1].range).toEqual [[6, 34], [6, 41]]
      expect(matches[1].lineText).toBe '      current < pivot ? left.push(current) : right.push(current);'
      expect(matches[1].lineTextOffset).toBe 0

  describe "::scanInRange(range, regex, fn)", ->
    beforeEach (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        done()

    describe "when given a regex with a ignore case flag", ->
      it "does a case-insensitive search", ->
        matches = []
        buffer.scanInRange /cuRRent/i, [[0,0], [12,0]], ({match, range}) ->
          matches.push(match)
        expect(matches.length).toBe 1

    describe "when given a regex with no global flag", ->
      it "calls the iterator with the first match for the given regex in the given range", ->
        matches = []
        ranges = []
        buffer.scanInRange /cu(rr)ent/, [[4,0], [6,44]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 1
        expect(ranges.length).toBe 1

        expect(matches[0][0]).toBe 'current'
        expect(matches[0][1]).toBe 'rr'
        expect(ranges[0]).toEqual [[5,6], [5,13]]

    describe "when given a regex with a global flag", ->
      it "calls the iterator with each match for the given regex in the given range", ->
        matches = []
        ranges = []
        buffer.scanInRange /cu(rr)ent/g, [[4,0], [6,59]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 3
        expect(ranges.length).toBe 3

        expect(matches[0][0]).toBe 'current'
        expect(matches[0][1]).toBe 'rr'
        expect(ranges[0]).toEqual [[5,6], [5,13]]

        expect(matches[1][0]).toBe 'current'
        expect(matches[1][1]).toBe 'rr'
        expect(ranges[1]).toEqual [[6,6], [6,13]]

        expect(matches[2][0]).toBe 'current'
        expect(matches[2][1]).toBe 'rr'
        expect(ranges[2]).toEqual [[6,34], [6,41]]

    describe "when the last regex match exceeds the end of the range", ->
      describe "when the portion of the match within the range also matches the regex", ->
        it "calls the iterator with the truncated match", ->
          matches = []
          ranges = []
          buffer.scanInRange /cu(r*)/g, [[4,0], [6,9]], ({match, range}) ->
            matches.push(match)
            ranges.push(range)

          expect(matches.length).toBe 2
          expect(ranges.length).toBe 2

          expect(matches[0][0]).toBe 'curr'
          expect(matches[0][1]).toBe 'rr'
          expect(ranges[0]).toEqual [[5,6], [5,10]]

          expect(matches[1][0]).toBe 'cur'
          expect(matches[1][1]).toBe 'r'
          expect(ranges[1]).toEqual [[6,6], [6,9]]

      describe "when the portion of the match within the range does not matches the regex", ->
        it "does not call the iterator with the truncated match", ->
          matches = []
          ranges = []
          buffer.scanInRange /cu(r*)e/g, [[4,0], [6,9]], ({match, range}) ->
            matches.push(match)
            ranges.push(range)

          expect(matches.length).toBe 1
          expect(ranges.length).toBe 1

          expect(matches[0][0]).toBe 'curre'
          expect(matches[0][1]).toBe 'rr'
          expect(ranges[0]).toEqual [[5,6], [5,11]]

    describe "when the iterator calls the 'replace' control function with a replacement string", ->
      it "replaces each occurrence of the regex match with the string", ->
        ranges = []
        buffer.scanInRange /cu(rr)ent/g, [[4,0], [6,59]], ({range, replace}) ->
          ranges.push(range)
          replace("foo")

        expect(ranges[0]).toEqual [[5,6], [5,13]]
        expect(ranges[1]).toEqual [[6,6], [6,13]]
        expect(ranges[2]).toEqual [[6,30], [6,37]]

        expect(buffer.lineForRow(5)).toBe '      foo = items.shift();'
        expect(buffer.lineForRow(6)).toBe '      foo < pivot ? left.push(foo) : right.push(current);'

      it "allows the match to be replaced with the empty string", ->
        buffer.scanInRange /current/g, [[4,0], [6,59]], ({replace}) ->
          replace("")

        expect(buffer.lineForRow(5)).toBe '       = items.shift();'
        expect(buffer.lineForRow(6)).toBe '       < pivot ? left.push() : right.push(current);'

    describe "when the iterator calls the 'stop' control function", ->
      it "stops the traversal", ->
        ranges = []
        buffer.scanInRange /cu(rr)ent/g, [[4,0], [6,59]], ({range, stop}) ->
          ranges.push(range)
          stop() if ranges.length == 2

        expect(ranges.length).toBe 2

  describe "::backwardsScanInRange(range, regex, fn)", ->
    beforeEach (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        done()

    describe "when given a regex with no global flag", ->
      it "calls the iterator with the last match for the given regex in the given range", ->
        matches = []
        ranges = []
        buffer.backwardsScanInRange /cu(rr)ent/, [[4,0], [6,44]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 1
        expect(ranges.length).toBe 1

        expect(matches[0][0]).toBe 'current'
        expect(matches[0][1]).toBe 'rr'
        expect(ranges[0]).toEqual [[6,34], [6,41]]

    describe "when given a regex with a global flag", ->
      it "calls the iterator with each match for the given regex in the given range, starting with the last match", ->
        matches = []
        ranges = []
        buffer.backwardsScanInRange /cu(rr)ent/g, [[4,0], [6,59]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 3
        expect(ranges.length).toBe 3

        expect(matches[0][0]).toBe 'current'
        expect(matches[0][1]).toBe 'rr'
        expect(ranges[0]).toEqual [[6,34], [6,41]]

        expect(matches[1][0]).toBe 'current'
        expect(matches[1][1]).toBe 'rr'
        expect(ranges[1]).toEqual [[6,6], [6,13]]

        expect(matches[2][0]).toBe 'current'
        expect(matches[2][1]).toBe 'rr'
        expect(ranges[2]).toEqual [[5,6], [5,13]]

    describe "when the last regex match starts at the beginning of the range", ->
      it "calls the iterator with the match", ->
        matches = []
        ranges = []
        buffer.scanInRange /quick/g, [[0,4], [2,0]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 1
        expect(ranges.length).toBe 1

        expect(matches[0][0]).toBe 'quick'
        expect(ranges[0]).toEqual [[0,4], [0,9]]

        matches = []
        ranges = []
        buffer.scanInRange /^/, [[0,0], [2,0]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 1
        expect(ranges.length).toBe 1

        expect(matches[0][0]).toBe ""
        expect(ranges[0]).toEqual [[0,0], [0,0]]

    describe "when the first regex match exceeds the end of the range", ->
      describe "when the portion of the match within the range also matches the regex", ->
        it "calls the iterator with the truncated match", ->
          matches = []
          ranges = []
          buffer.backwardsScanInRange /cu(r*)/g, [[4,0], [6,9]], ({match, range}) ->
            matches.push(match)
            ranges.push(range)

          expect(matches.length).toBe 2
          expect(ranges.length).toBe 2

          expect(matches[0][0]).toBe 'cur'
          expect(matches[0][1]).toBe 'r'
          expect(ranges[0]).toEqual [[6,6], [6,9]]

          expect(matches[1][0]).toBe 'curr'
          expect(matches[1][1]).toBe 'rr'
          expect(ranges[1]).toEqual [[5,6], [5,10]]

      describe "when the portion of the match within the range does not matches the regex", ->
        it "does not call the iterator with the truncated match", ->
          matches = []
          ranges = []
          buffer.backwardsScanInRange /cu(r*)e/g, [[4,0], [6,9]], ({match, range}) ->
            matches.push(match)
            ranges.push(range)

          expect(matches.length).toBe 1
          expect(ranges.length).toBe 1

          expect(matches[0][0]).toBe 'curre'
          expect(matches[0][1]).toBe 'rr'
          expect(ranges[0]).toEqual [[5,6], [5,11]]

    describe "when the iterator calls the 'replace' control function with a replacement string", ->
      it "replaces each occurrence of the regex match with the string", ->
        ranges = []
        buffer.backwardsScanInRange /cu(rr)ent/g, [[4,0], [6,59]], ({range, replace}) ->
          ranges.push(range)
          replace("foo") unless range.start.isEqual([6,6])

        expect(ranges[0]).toEqual [[6,34], [6,41]]
        expect(ranges[1]).toEqual [[6,6], [6,13]]
        expect(ranges[2]).toEqual [[5,6], [5,13]]

        expect(buffer.lineForRow(5)).toBe '      foo = items.shift();'
        expect(buffer.lineForRow(6)).toBe '      current < pivot ? left.push(foo) : right.push(current);'

    describe "when the iterator calls the 'stop' control function", ->
      it "stops the traversal", ->
        ranges = []
        buffer.backwardsScanInRange /cu(rr)ent/g, [[4,0], [6,59]], ({range, stop}) ->
          ranges.push(range)
          stop() if ranges.length == 2

        expect(ranges.length).toBe 2
        expect(ranges[0]).toEqual [[6,34], [6,41]]
        expect(ranges[1]).toEqual [[6,6], [6,13]]

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

  describe "::characterIndexForPosition(position)", ->
    beforeEach (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        done()

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
    beforeEach (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        done()

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
    beforeEach (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        done()

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

  describe "::onDidChangeText(callback)",  ->
    beforeEach (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        done()

    it "notifies observers after a transaction, an undo or a redo", ->
      textChanges = []
      buffer.onDidChangeText ({changes}) -> textChanges.push(changes...)

      buffer.insert([0, 0], "abc")
      buffer.delete([[0, 0], [0, 1]])
      expect(textChanges).toEqual([
        {
          start: {row: 0, column: 0},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 3},
          newText: "abc"
        },
        {
          start: {row: 0, column: 0},
          oldExtent: {row: 0, column: 1},
          newExtent: {row: 0, column: 0},
          newText: ""
        }
      ])

      textChanges = []
      buffer.transact ->
        buffer.insert([1, 0], "x")
        buffer.insert([1, 1], "y")
        buffer.insert([2, 3], "zw")
        buffer.delete([[2, 3], [2, 4]])

      expect(textChanges).toEqual([
        {
          start: {row: 1, column: 0},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 2},
          newText: "xy"
        },
        {
          start: {row: 2, column: 3},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 1},
          newText: "w"
        }
      ])

      textChanges = []
      buffer.undo()
      expect(textChanges).toEqual([
        {
          start: {row: 1, column: 0},
          oldExtent: {row: 0, column: 2},
          newExtent: {row: 0, column: 0},
          newText: ""
        },
        {
          start: {row: 2, column: 3},
          oldExtent: {row: 0, column: 1},
          newExtent: {row: 0, column: 0},
          newText: ""
        }
      ])

      textChanges = []
      buffer.redo()
      expect(textChanges).toEqual([
        {
          start: {row: 1, column: 0},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 2},
          newText: "xy"
        },
        {
          start: {row: 2, column: 3},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 1},
          newText: "w"
        }
      ])

      textChanges = []
      buffer.transact ->
        buffer.transact ->
          buffer.insert([0, 0], "j")

      # we emit only one event for nested transactions
      expect(textChanges).toEqual([
        {
          start: {row: 0, column: 0},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 1},
          newText: "j"
        }
      ])

    it "doesn't throw an error when clearing the undo stack within a transaction", ->
      buffer.onDidChangeText(didChangeTextSpy = jasmine.createSpy())
      expect(-> buffer.transact(-> buffer.clearUndoStack())).not.toThrowError()
      expect(didChangeTextSpy).not.toHaveBeenCalled()

  describe "::onDidStopChanging(callback)", ->
    [delay, didStopChangingCallback] = []
    beforeEach (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        done()

    beforeEach (done) ->
      delay = buffer.stoppedChangingDelay
      didStopChangingCallback = jasmine.createSpy("didStopChangingCallback")
      setTimeout(->
        done()
      , delay)

    beforeEach (done) ->
      buffer.onDidStopChanging didStopChangingCallback

      buffer.insert([0, 0], 'a')
      expect(didStopChangingCallback).not.toHaveBeenCalled()
      setTimeout(->
        done()
      , delay / 2)

    beforeEach (done) ->
      buffer.transact ->
        buffer.transact ->
          buffer.insert([0, 0], 'b')
          buffer.insert([1, 0], 'c')
      expect(didStopChangingCallback).not.toHaveBeenCalled()
      setTimeout(->
        done()
      , delay / 2)

    beforeEach (done) ->
      expect(didStopChangingCallback).not.toHaveBeenCalled()
      setTimeout(->
        done()
      , delay / 2)

    beforeEach (done) ->
      expect(didStopChangingCallback).toHaveBeenCalled()
      expect(didStopChangingCallback.calls.mostRecent().args[0].changes).toEqual [
        {
          start: {row: 0, column: 0},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 2},
          newText: 'ba'
        },
        {
          start: {row: 1, column: 0},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 1},
          newText: 'c'
        }
      ]

      didStopChangingCallback.calls.reset()
      buffer.undo()
      buffer.undo()
      setTimeout(->
        done()
      , delay)

    it "notifies observers after a delay passes following changes", ->
        expect(didStopChangingCallback).toHaveBeenCalled()

  describe "::append(text)", ->
    beforeEach (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        done()

    it "adds text to the end of the buffer", ->
      buffer.setText("")
      buffer.append("a")
      expect(buffer.getText()).toBe "a"
      buffer.append("b\nc")
      expect(buffer.getText()).toBe "ab\nc"

  describe "line ending support", ->
    beforeEach (done) ->
      filePath = require.resolve('./fixtures/sample.js')
      buffer = new TextBuffer({filePath, load: false})
      buffer.load().then ->
        done()

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

      it "persists across serialization and deserialization", ->
        bufferA = new TextBuffer
        bufferA.setPreferredLineEnding("\r\n")

        bufferB = TextBuffer.deserialize(bufferA.serialize())
        expect(bufferB.getPreferredLineEnding()).toBe "\r\n"

  describe "character set encoding support", ->
    it "allows the encoding to be set on creation", (done) ->
      filePath = join(__dirname, 'fixtures', 'win1251.txt')
      buffer = new TextBuffer({filePath, load: false, encoding: 'win1251'})
      buffer.load().then ->
        expect(buffer.getEncoding()).toBe 'win1251'
        expect(buffer.getText()).toBe 'тест 1234 абвгдеёжз'
        done()

    it "serializes the encoding", (done) ->
      filePath = join(__dirname, 'fixtures', 'win1251.txt')
      bufferA = new TextBuffer({filePath, load: false, encoding: 'win1251'})
      bufferA.load().then ->
        bufferB = TextBuffer.deserialize(bufferA.serialize())
        expect(bufferB.getEncoding()).toBe 'win1251'
        expect(bufferB.getText()).toBe 'тест 1234 абвгдеёжз'
        done()

    describe "when the buffer is modified", ->
      describe "when the encoding of the buffer is changed", ->
        beforeEach (done) ->
          filePath = join(__dirname, 'fixtures', 'win1251.txt')
          buffer = new TextBuffer({filePath, load: false})
          buffer.load().then ->
            done()

        it "does not reload the contents from the disk", ->
          spyOn(buffer, 'updateCachedDiskContents')
          buffer.setText('ch ch changes')
          buffer.setEncoding('win1251')
          expect(buffer.updateCachedDiskContents.calls.count()).toBe 0

    describe "when the buffer is unmodified", ->
      describe "when the encoding of the buffer is changed", ->
        beforeEach (done) ->
          filePath = join(__dirname, 'fixtures', 'win1251.txt')
          buffer = new TextBuffer({filePath, load: false})
          buffer.load().then ->
            done()

        beforeEach (done) ->
          expect(buffer.getEncoding()).toBe 'utf8'
          expect(buffer.getText()).not.toBe 'тест 1234 абвгдеёжз'

          reloadHandler = ->
            done()
          buffer.setEncoding('win1251')
          expect(buffer.getEncoding()).toBe 'win1251'
          buffer.onDidReload(reloadHandler)

        it "reloads the contents from the disk", ->
          expect(buffer.getText()).toBe 'тест 1234 абвгдеёжз'

    it "emits an event when the encoding changes", ->
      filePath = join(__dirname, 'fixtures', 'win1251.txt')
      encodingChangeHandler = jasmine.createSpy('encodingChangeHandler')

      buffer = new TextBuffer({filePath, load: true})
      buffer.onDidChangeEncoding(encodingChangeHandler)
      buffer.setEncoding('win1251')
      expect(encodingChangeHandler).toHaveBeenCalledWith('win1251')

      encodingChangeHandler.calls.reset()
      buffer.setEncoding('win1251')
      expect(encodingChangeHandler.calls.count()).toBe 0

      encodingChangeHandler.calls.reset()

      buffer = new TextBuffer()
      buffer.onDidChangeEncoding(encodingChangeHandler)
      buffer.setEncoding('win1251')
      expect(encodingChangeHandler).toHaveBeenCalledWith('win1251')

      encodingChangeHandler.calls.reset()
      buffer.setEncoding('win1251')
      expect(encodingChangeHandler.calls.count()).toBe 0

    describe "when a buffer's encoding is changed", ->
      beforeEach (done) ->
        filePath = join(__dirname, 'fixtures', 'win1251.txt')
        buffer = new TextBuffer({filePath, load: false})
        reloadHandler = ->
          done()
        buffer.load().then ->
          buffer.onDidReload(reloadHandler)
          buffer.setEncoding('win1251')

      it "does not push the encoding change onto the undo stack", ->
        buffer.undo()
        expect(buffer.getText()).toBe 'тест 1234 абвгдеёжз'
