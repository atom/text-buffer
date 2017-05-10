const fs = require('fs-plus')
const path = require('path')
const temp = require('temp')
const Point = require('../src/point')
const Range = require('../src/range')
const TextBuffer = require('../src/text-buffer')

describe("TextBuffer IO", () => {
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
      buffer.onWillChange(event => changeEvents.push(['will-change', event]))
      buffer.onDidChange(event => changeEvents.push(['did-change', event]))
      buffer.onDidChangeText(event => changeEvents.push(['did-change-text', event]))

      buffer.load().then(result => {
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
      buffer.onWillChange(event => changeEvents.push(event))
      buffer.onDidChange(event => changeEvents.push(event))
      buffer.onDidChangeText(event => changeEvents.push(event))

      buffer.load().then(result => {
        expect(result).toBe(false)
        expect(buffer.getText()).toBe('def')
        expect(changeEvents).toEqual([])
        done()
      })
    })

    it('does nothing if the buffer is modified before the load completes', (done) => {
      const changeEvents = []

      buffer.load().then(result => {
        expect(result).toBe(false)
        expect(buffer.getText()).toBe('def')
        expect(changeEvents).toEqual([])
        done()
      })

      buffer.setText('def')
      buffer.onWillChange(event => changeEvents.push(event))
      buffer.onDidChange(event => changeEvents.push(event))
      buffer.onDidChangeText(event => changeEvents.push(event))
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
      buffer.onWillChange(event => changeEvents.push(['will-change', event]))
      buffer.onDidChange(event => changeEvents.push(['did-change', event]))
      buffer.onDidChangeText(event => changeEvents.push(['did-change-text', event]))

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
      buffer.onWillChange(event => changeEvents.push(event))
      buffer.onDidChange(event => changeEvents.push(event))
      buffer.onDidChangeText(event => changeEvents.push(event))

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
      buffer.onWillChange(event => {
        expect(buffer.getText()).toEqual('abcde')
        changeEvents.push(['will-change', event])
      })
      buffer.onDidChange(event => {
        expect(buffer.getText()).toEqual(newText)
        changeEvents.push(['did-change', event])
      })
      buffer.onDidChangeText(event => {
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
      buffer.onWillChange(event => changeEvents.push(['will-change', event]))
      buffer.onDidChange(event => changeEvents.push(['did-change', event]))
      buffer.onDidChangeText(event => changeEvents.push(['did-change-text', event]))

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

  describe('.save', () => {
    let filePath

    beforeEach(() => {
      const tempDir = temp.mkdirSync()
      filePath = path.join(tempDir, 'temp.txt')
      fs.writeFileSync(filePath, '')
      buffer = new TextBuffer({filePath})
    })

    it('saves the contents of the buffer to the path', () => {
      buffer.setText('Buffer contents')
      buffer.save()
      expect(fs.readFileSync(filePath, 'utf8')).toEqual('Buffer contents')
    })

    it('does not emit a change event', (done) => {
      buffer.setText('Buffer contents')
      expect(buffer.isModified()).toBe(true)

      const changeEvents = []
      buffer.onWillChange(event => changeEvents.push(['will-change', event]))
      buffer.onDidChange(event => changeEvents.push(['did-change', event]))
      buffer.onDidChangeText(event => changeEvents.push(['did-change-text', event]))

      buffer.save()
      expect(buffer.isModified()).toBe(false)

      setTimeout(() => {
        expect(changeEvents).toEqual([])
        done()
      }, 250)
    })

    it('notifies ::onWillSave and ::onDidSave observers', () => {
      const events = []
      buffer.onWillSave(event => events.push(['will-save-1', event]))
      buffer.onWillSave(event => events.push(['will-save-2', event]))
      spyOn(buffer.buffer, 'saveSync').and.callFake(() => events.push('saveSync'))
      buffer.onDidSave(event => events.push(['did-save-1', event]))
      buffer.onDidSave(event => events.push(['did-save-2', event]))

      buffer.setText('Buffer contents')
      buffer.save()
      const path = buffer.getPath()
      expect(events).toEqual([
        ['will-save-1', {path}],
        ['will-save-2', {path}],
        'saveSync',
        ['did-save-1', {path}],
        ['did-save-2', {path}]
      ])
    })

    describe('when a conflict is created', () => {
      beforeEach((done) => {
        buffer.setText('a')
        buffer.save()
        buffer.setText('ab')
        buffer.onDidConflict(() => done())
        fs.writeFileSync(buffer.getPath(), 'c')
      })

      it('no longer reports being in conflict when the buffer is saved again', () => {
        expect(buffer.isInConflict()).toBe(true)
        buffer.save()
        expect(buffer.isInConflict()).toBe(false)
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

    it('saves the contents of the buffer to the new path', () => {
      const didChangePathHandler = jasmine.createSpy('didChangePathHandler')
      buffer.onDidChangePath(didChangePathHandler)

      const newPath = temp.openSync('atom').path
      buffer.setText('b')
      buffer.saveAs(newPath)
      expect(fs.readFileSync(newPath, 'utf8')).toEqual('b')

      expect(didChangePathHandler).toHaveBeenCalledWith(newPath)
    })

    it('stops listening for changes to the old path and starts listening for changes to the new path', (done) => {
      const didChangeHandler = jasmine.createSpy('didChangeHandler')
      buffer.onDidChange(didChangeHandler)

      const newPath = temp.openSync('atom').path
      buffer.saveAs(newPath)
      expect(didChangeHandler).not.toHaveBeenCalled()

      fs.writeFileSync(filePath, 'does not trigger a buffer change')
      timeoutPromise(100)
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
})

function timeoutPromise (duration) {
  return new Promise(resolve => setTimeout(resolve, duration))
}

function toPlainObject (value) {
  return JSON.parse(JSON.stringify(value))
}