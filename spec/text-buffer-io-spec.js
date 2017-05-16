const fs = require('fs-plus')
const path = require('path')
const temp = require('temp')
const Point = require('../src/point')
const Range = require('../src/range')
const TextBuffer = require('../src/text-buffer')

describe('TextBuffer IO', () => {
  let buffer

  afterEach(() => {
    if (buffer) buffer.destroy()
  })

  describe('.load', () => {
    beforeEach(() => {
      const filePath = temp.openSync('atom').path
      fs.writeFileSync(filePath, 'abc')
      buffer = new TextBuffer({filePath})
    })

    it('updates the buffer and notifies change observers', (done) => {
      const changeEvents = []
      buffer.onWillChange((event) => changeEvents.push(['will-change', event]))
      buffer.onDidChange((event) => changeEvents.push(['did-change', event]))
      buffer.onDidChangeText((event) => changeEvents.push(['did-change-text', event]))

      buffer.load().then((result) => {
        expect(result).toBe(true)
        expect(buffer.getText()).toBe('abc')
        expect(toPlainObject(changeEvents)).toEqual(toPlainObject([
          [
            'will-change', {
              oldRange: Range(Point.ZERO, Point.ZERO)
            }
          ],
          [
            'did-change', {
              oldRange: Range(Point.ZERO, Point.ZERO),
              newRange: Range(Point.ZERO, Point(0, 3)),
              oldText: '',
              newText: 'abc'
            }
          ],
          [
            'did-change-text', {
              changes: [{
                oldRange: Range(Point.ZERO, Point.ZERO),
                newRange: Range(Point.ZERO, Point(0, 3)),
                oldText: '',
                newText: 'abc'
              }]
            }
          ]
        ]))
        done()
      })
    })

    it('does nothing if the buffer is already modified', (done) => {
      buffer.setText('def')

      const changeEvents = []
      buffer.onWillChange((event) => changeEvents.push(event))
      buffer.onDidChange((event) => changeEvents.push(event))
      buffer.onDidChangeText((event) => changeEvents.push(event))

      buffer.load().then((result) => {
        expect(result).toBe(false)
        expect(buffer.getText()).toBe('def')
        expect(changeEvents).toEqual([])
        done()
      })
    })

    it('does nothing if the buffer is modified before the load completes', (done) => {
      const changeEvents = []

      buffer.load().then((result) => {
        expect(result).toBe(false)
        expect(buffer.getText()).toBe('def')
        expect(changeEvents).toEqual([])
        done()
      })

      buffer.setText('def')
      buffer.onWillChange((event) => changeEvents.push(event))
      buffer.onDidChange((event) => changeEvents.push(event))
      buffer.onDidChangeText((event) => changeEvents.push(event))
    })
  })

  describe('.loadSync', () => {
    beforeEach(() => {
      const filePath = temp.openSync('atom').path
      fs.writeFileSync(filePath, 'abc')
      buffer = new TextBuffer({filePath})
    })

    it('updates the buffer and notifies change observers', () => {
      const changeEvents = []
      buffer.onWillChange((event) => changeEvents.push(['will-change', event]))
      buffer.onDidChange((event) => changeEvents.push(['did-change', event]))
      buffer.onDidChangeText((event) => changeEvents.push(['did-change-text', event]))

      const result = buffer.loadSync()
      expect(result).toBe(true)
      expect(buffer.getText()).toBe('abc')
      expect(toPlainObject(changeEvents)).toEqual(toPlainObject([
        [
          'will-change', {
            oldRange: Range(Point.ZERO, Point.ZERO)
          }
        ],
        [
          'did-change', {
            oldRange: Range(Point.ZERO, Point.ZERO),
            newRange: Range(Point.ZERO, Point(0, 3)),
            oldText: '',
            newText: 'abc'
          }
        ],
        [
          'did-change-text', {
            changes: [{
              oldRange: Range(Point.ZERO, Point.ZERO),
              newRange: Range(Point.ZERO, Point(0, 3)),
              oldText: '',
              newText: 'abc'
            }]
          }
        ]
      ]))
    })

    it('does nothing if the buffer is modified', () => {
      buffer.setText('def')

      const changeEvents = []
      buffer.onWillChange((event) => changeEvents.push(event))
      buffer.onDidChange((event) => changeEvents.push(event))
      buffer.onDidChangeText((event) => changeEvents.push(event))

      const result = buffer.loadSync()
      expect(result).toBe(false)
      expect(buffer.getText()).toBe('def')
      expect(changeEvents).toEqual([])
    })
  })

  describe('.reload', () => {
    beforeEach(() => {
      const filePath = temp.openSync('atom').path
      fs.writeFileSync(filePath, 'abc')
      buffer = new TextBuffer({filePath})
    })

    it('it updates the buffer even if it is modified', (done) => {
      const events = []

      buffer.onWillReload(() => events.push('will-reload'))
      buffer.onDidReload(() => events.push('did-reload'))
      buffer.reload().then(() => {
        expect(events).toEqual(['will-reload', 'did-reload'])
        done()
      })
    })
  })

  describe('.save', () => {
    let filePath

    beforeEach(() => {
      const tempDir = temp.mkdirSync()
      filePath = path.join(tempDir, 'temp.txt')
      fs.writeFileSync(filePath, '')
      buffer = new TextBuffer({filePath})
    })

    it('saves the contents of the buffer to the path', (done) => {
      buffer.setText('Buffer contents')
      buffer.save().then(() => {
        expect(fs.readFileSync(filePath, 'utf8')).toEqual('Buffer contents')
        done()
      })
    })

    it('does not emit a change event', (done) => {
      buffer.setText('Buffer contents')
      expect(buffer.isModified()).toBe(true)

      const changeEvents = []
      buffer.onWillChange((event) => changeEvents.push(['will-change', event]))
      buffer.onDidChange((event) => changeEvents.push(['did-change', event]))
      buffer.onDidChangeText((event) => changeEvents.push(['did-change-text', event]))

      buffer.save().then(() => {
        expect(buffer.isModified()).toBe(false)

        setTimeout(() => {
          expect(changeEvents).toEqual([])
          done()
        }, 250)
      })
    })

    it('notifies ::onWillSave and ::onDidSave observers', (done) => {
      const events = []
      buffer.onWillSave((event) => events.push([
        'will-save',
        event,
        fs.readFileSync(filePath, 'utf8')
      ]))
      buffer.onDidSave((event) => events.push([
        'did-save',
        event,
        fs.readFileSync(filePath, 'utf8')
      ]))

      buffer.setText('Buffer contents')
      buffer.save().then(() => {
        const path = buffer.getPath()
        expect(events).toEqual([
          ['will-save', {path}, ''],
          ['did-save', {path}, 'Buffer contents']
        ])
        done()
      })
    })

    describe('when a conflict is created', () => {
      beforeEach((done) => {
        buffer.setText('a')
        buffer.save()
        buffer.setText('ab')
        buffer.onDidConflict(() => done())
        fs.writeFileSync(buffer.getPath(), 'c')
      })

      it('no longer reports being in conflict when the buffer is saved again', (done) => {
        expect(buffer.isInConflict()).toBe(true)
        buffer.save().then(() => {
          expect(buffer.isInConflict()).toBe(false)
          done()
        })
      })
    })

    describe('when the buffer has no path', () => {
      it('throws an exception', () => {
        buffer = new TextBuffer()
        buffer.setText('hi')
        expect(() => buffer.save()).toThrowError()
      })
    })
  })

  describe('.saveAs', () => {
    let filePath

    beforeEach((done) => {
      filePath = temp.openSync('atom').path
      fs.writeFileSync(filePath, 'a')
      buffer = new TextBuffer({filePath})
      buffer.load().then(done)
    })

    it('saves the contents of the buffer to the new path', (done) => {
      const didChangePathHandler = jasmine.createSpy('didChangePathHandler')
      buffer.onDidChangePath(didChangePathHandler)

      const newPath = temp.openSync('atom').path
      buffer.setText('b')
      buffer.saveAs(newPath).then(() => {
        expect(fs.readFileSync(newPath, 'utf8')).toEqual('b')
        expect(didChangePathHandler).toHaveBeenCalledWith(newPath)
        done()
      })
    })

    it('stops listening for changes to the old path and starts listening for changes to the new path', (done) => {
      const didChangeHandler = jasmine.createSpy('didChangeHandler')
      buffer.onDidChange(didChangeHandler)

      const newPath = temp.openSync('atom').path
      buffer.saveAs(newPath)
        .then(() => {
          expect(didChangeHandler).not.toHaveBeenCalled()
          fs.writeFileSync(filePath, 'does not trigger a buffer change')
          return timeoutPromise(100)
        })
        .then(() => {
          expect(didChangeHandler).not.toHaveBeenCalled()
          expect(buffer.getText()).toBe('a')
        })
        .then(() => {
          fs.writeFileSync(newPath, 'does trigger a buffer change')
          return timeoutPromise(100)
        })
        .then(() => {
          expect(didChangeHandler).toHaveBeenCalled()
          expect(buffer.getText()).toBe('does trigger a buffer change')
          done()
        })
    })
  })

  describe('.isModified', () => {
    beforeEach((done) => {
      const filePath = temp.openSync('atom').path
      fs.writeFileSync(filePath, '')
      buffer = new TextBuffer({filePath})
      buffer.load().then(done)
    })

    describe('when the buffer is changed', () => {
      it('reports the modified status changing to true or false', (done) => {
        const modifiedStatusChanges = []
        buffer.onDidChangeModified((status) => modifiedStatusChanges.push(status))
        expect(buffer.isModified()).toBeFalsy()

        buffer.insert([0, 0], 'hi')
        expect(buffer.isModified()).toBe(true)

        stopChangingPromise()
          .then(() => {
            expect(modifiedStatusChanges).toEqual([true])

            buffer.insert([0, 2], 'ho')
            expect(buffer.isModified()).toBe(true)
            return stopChangingPromise()
          })
          .then(() => {
            expect(modifiedStatusChanges).toEqual([true])

            buffer.undo()
            buffer.undo()
            expect(buffer.isModified()).toBe(false)
            return stopChangingPromise()
          })
          .then(() => {
            expect(modifiedStatusChanges).toEqual([true, false])
            done()
          })
      })
    })

    describe('when the buffer is saved', () => {
      it('reports the modified status changing to false', (done) => {
        buffer.insert([0, 0], 'hi')
        expect(buffer.isModified()).toBe(true)

        const modifiedStatusChanges = []
        buffer.onDidChangeModified((status) => modifiedStatusChanges.push(status))

        buffer.save().then(() => {
          expect(buffer.isModified()).toBe(false)
          stopChangingPromise().then(() => {
            expect(modifiedStatusChanges).toEqual([false])
            done()
          })
        })
      })
    })

    describe('when the buffer is reloaded', () => {
      it('reports the modified status changing to false', (done) => {
        buffer.insert([0, 0], 'hi')
        expect(buffer.isModified()).toBe(true)

        const modifiedStatusChanges = []
        buffer.onDidChangeModified((status) => modifiedStatusChanges.push(status))

        buffer.reload().then(() => {
          expect(buffer.isModified()).toBe(false)
          expect(modifiedStatusChanges).toEqual([false])
          done()
        })
      })
    })

    it('returns false for an empty buffer with no path', () => {
      const buffer = new TextBuffer()
      expect(buffer.isModified()).toBeFalsy()
      buffer.append('hello')
      expect(buffer.isModified()).toBeTruthy()
    })

    it('returns true for a non-empty buffer with no path', () => {
      const buffer = new TextBuffer({text: 'something'})
      expect(buffer.isModified()).toBeTruthy()

      buffer.append('a')
      expect(buffer.isModified()).toBeTruthy()

      buffer.setText('')
      expect(buffer.isModified()).toBeFalsy()
    })

    it('returns false until the buffer is fully loaded', () => {
      const buffer = new TextBuffer({filePath: '/some/path'})
      expect(buffer.isModified()).toBeFalsy()
    })
  })

  describe('encoding support', () => {
    it('allows the encoding to be set on creation', (done) => {
      const filePath = path.join(__dirname, 'fixtures', 'win1251.txt')
      const buffer = new TextBuffer({filePath, load: false, encoding: 'WINDOWS-1251'})
      buffer.load().then(() => {
        expect(buffer.getEncoding()).toBe('WINDOWS-1251')
        expect(buffer.getText()).toBe('тест 1234 абвгдеёжз')
        done()
      })
    })

    it('serializes the encoding', (done) => {
      const filePath = path.join(__dirname, 'fixtures', 'win1251.txt')
      const bufferA = new TextBuffer({filePath, load: false, encoding: 'WINDOWS-1251'})
      bufferA.load().then(() => {
        const bufferB = TextBuffer.deserialize(bufferA.serialize())
        bufferB.load().then(() => {
          expect(bufferB.getEncoding()).toBe('WINDOWS-1251')
          expect(bufferB.getText()).toBe('тест 1234 абвгдеёжз')
          done()
        })
      })
    })

    describe('when the buffer is modified', () => {
      describe('when the encoding of the buffer is changed', () => {
        beforeEach((done) => {
          const filePath = path.join(__dirname, 'fixtures', 'win1251.txt')
          buffer = new TextBuffer({filePath, load: false})
          buffer.load().then(done)
        })

        it('does not reload the contents from the disk', () => {
          spyOn(buffer, 'load')
          buffer.setText('ch ch changes')
          buffer.setEncoding('win1251')
          expect(buffer.load.calls.count()).toBe(0)
        })
      })
    })

    describe('when the buffer is unmodified', () => {
      describe('when the encoding of the buffer is changed', () => {
        beforeEach((done) => {
          const filePath = path.join(__dirname, 'fixtures', 'win1251.txt')
          buffer = new TextBuffer({filePath, load: false})
          buffer.load().then(done)
        })

        beforeEach((done) => {
          expect(buffer.getEncoding()).toBe('utf8')
          expect(buffer.getText()).not.toBe('тест 1234 абвгдеёжз')

          buffer.setEncoding('WINDOWS-1251')
          expect(buffer.getEncoding()).toBe('WINDOWS-1251')
          buffer.onDidChange(done)
        })

        it('reloads the contents from the disk', () => {
          expect(buffer.getText()).toBe('тест 1234 абвгдеёжз')
        })
      })
    })

    it('emits an event when the encoding changes', () => {
      const filePath = path.join(__dirname, 'fixtures', 'win1251.txt')
      const encodingChangeHandler = jasmine.createSpy('encodingChangeHandler')

      let buffer = new TextBuffer({filePath, load: true})
      buffer.onDidChangeEncoding(encodingChangeHandler)
      buffer.setEncoding('WINDOWS-1251')
      expect(encodingChangeHandler).toHaveBeenCalledWith('WINDOWS-1251')

      encodingChangeHandler.calls.reset()
      buffer.setEncoding('WINDOWS-1251')
      expect(encodingChangeHandler.calls.count()).toBe(0)

      encodingChangeHandler.calls.reset()

      buffer = new TextBuffer()
      buffer.onDidChangeEncoding(encodingChangeHandler)
      buffer.setEncoding('WINDOWS-1251')
      expect(encodingChangeHandler).toHaveBeenCalledWith('WINDOWS-1251')

      encodingChangeHandler.calls.reset()
      buffer.setEncoding('WINDOWS-1251')
      expect(encodingChangeHandler.calls.count()).toBe(0)
    })

    describe("when a buffer's encoding is changed", () => {
      beforeEach((done) => {
        const filePath = path.join(__dirname, 'fixtures', 'win1251.txt')
        buffer = new TextBuffer({filePath, load: false})
        buffer.load().then(() => {
          buffer.onDidChange(done)
          buffer.setEncoding('WINDOWS-1251')
        })
      })

      it('does not push the encoding change onto the undo stack', () => {
        buffer.undo()
        expect(buffer.getText()).toBe('тест 1234 абвгдеёжз')
      })
    })
  })

  describe('when the file changes on disk', () => {
    beforeEach((done) => {
      const filePath = temp.openSync('atom').path
      fs.writeFileSync(filePath, 'abcde')
      buffer = new TextBuffer({filePath})
      buffer.load().then(done)
    })

    it('emits a conflict event if the file is modified', (done) => {
      buffer.append('f')
      expect(buffer.getText()).toBe('abcdef')
      expect(buffer.isModified()).toBe(true)

      fs.writeFileSync(buffer.getPath(), '  abc')

      const subscription = buffer.onDidConflict(() => {
        subscription.dispose()
        expect(buffer.getText()).toBe('abcdef')
        expect(buffer.isModified()).toBe(true)
        expect(buffer.isInConflict()).toBe(true)
        done()
      })
    })

    it('updates the buffer and its markers and notifies change observers if the buffer is unmodified', (done) => {
      expect(buffer.getText()).toEqual('abcde')

      const newTextSuffix = '!'.repeat(1024)
      const newText = ' abc' + newTextSuffix

      const changeEvents = []
      buffer.onWillChange((event) => {
        expect(buffer.getText()).toEqual('abcde')
        changeEvents.push(['will-change', event])
      })
      buffer.onDidChange((event) => {
        expect(buffer.getText()).toEqual(newText)
        changeEvents.push(['did-change', event])
      })
      buffer.onDidChangeText((event) => {
        expect(buffer.getText()).toEqual(newText)
        changeEvents.push(['did-change-text', event])
      })

      const markerB = buffer.markRange(Range(Point(0, 1), Point(0, 2)))
      const markerD = buffer.markRange(Range(Point(0, 3), Point(0, 4)))

      fs.writeFileSync(buffer.getPath(), newText)

      const subscription = buffer.onDidChangeText(() => {
        subscription.dispose()

        expect(buffer.isModified()).toBe(false)
        expect(buffer.getText()).toBe(newText)

        expect(markerB.getRange()).toEqual(Range(Point(0, 2), Point(0, 3)))
        expect(markerD.getRange()).toEqual(Range(Point(0, 4), Point(0, newText.length)))
        expect(markerB.isValid()).toBe(true)
        expect(markerD.isValid()).toBe(false)

        expect(toPlainObject(changeEvents)).toEqual(toPlainObject([
          [
            'will-change', {
              oldRange: Range(Point(0, 0), Point(0, 5))
            }
          ],
          [
            'did-change', {
              oldRange: Range(Point(0, 0), Point(0, 5)),
              newRange: Range(Point(0, 0), Point(0, newText.length)),
              oldText: 'abcde',
              newText: newText
            }
          ],
          [
            'did-change-text', {
              changes: [
                {
                  oldRange: Range(Point.ZERO, Point.ZERO),
                  newRange: Range(Point.ZERO, Point(0, 1)),
                  oldText: '',
                  newText: ' '
                },
                {
                  oldRange: Range(Point(0, 3), Point(0, 5)),
                  newRange: Range(Point(0, 4), Point(0, newText.length)),
                  oldText: 'de',
                  newText: newTextSuffix
                }
              ]
            }
          ]
        ]))

        done()
      })
    })

    it('does not fire duplicate change events when multiple changes happen on disk', (done) => {
      const changeEvents = []
      buffer.onWillChange((event) => changeEvents.push(['will-change', event]))
      buffer.onDidChange((event) => changeEvents.push(['did-change', event]))
      buffer.onDidChangeText((event) => changeEvents.push(['did-change-text', event]))

      fs.writeFileSync(buffer.getPath(), ' abc')
      fs.writeFileSync(buffer.getPath(), ' abcd')
      fs.writeFileSync(buffer.getPath(), ' abcde')
      fs.writeFileSync(buffer.getPath(), ' abcdef')
      fs.writeFileSync(buffer.getPath(), ' abcdefg')

      setTimeout(() => {
        expect(changeEvents.map(([type]) => type)).toEqual(['will-change', 'did-change', 'did-change-text'])
        done()
      }, 200)
    })
  })

  describe('when the is deleted', () => {
    let filePath

    beforeEach((done) => {
      filePath = path.join(temp.mkdirSync(), 'file-to-delete')
      fs.writeFileSync(filePath, 'delete me')
      buffer = new TextBuffer({filePath})
      filePath = buffer.getPath() // symlinks may have been converted
      buffer.load().then(done)
    })

    afterEach(() => buffer && buffer.destroy())

    describe('when the file is modified', () => {
      beforeEach((done) => {
        buffer.setText('I WAS MODIFIED')
        expect(buffer.isModified()).toBeTruthy()
        buffer.file.onDidDelete(() => done())
        fs.removeSync(filePath)
      })

      it('retains its path and reports the buffer as modified', () => {
        expect(buffer.getPath()).toBe(filePath)
        expect(buffer.isModified()).toBeTruthy()
      })
    })

    describe('when the file is not modified', () => {
      beforeEach((done) => {
        expect(buffer.isModified()).toBeFalsy()
        buffer.file.onDidDelete(() => done())
        fs.removeSync(filePath)
      })

      it('retains its path and reports the buffer as modified', () => {
        expect(buffer.getPath()).toBe(filePath)
        expect(buffer.isModified()).toBeTruthy()
      })
    })

    describe('when the file is deleted', () =>
      it('notifies all onDidDelete listeners ', (done) => {
        buffer.onDidDelete(() => done())
        fs.removeSync(filePath)
      })
    )

    it('resumes watching of the file when it is re-saved', (done) => {
      buffer.save()
      expect(fs.existsSync(buffer.getPath())).toBeTruthy()
      expect(buffer.isInConflict()).toBeFalsy()

      fs.writeFileSync(filePath, 'moo')
      buffer.onDidChange(done)
    })
  })
})

function stopChangingPromise () {
  return timeoutPromise(TextBuffer.prototype.stoppedChangingDelay)
}

function timeoutPromise (duration) {
  return new Promise((resolve) => setTimeout(resolve, duration))
}

function toPlainObject (value) {
  return JSON.parse(JSON.stringify(value))
}
