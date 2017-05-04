const fs = require('fs-plus')
const temp = require('temp')
const Point = require('../src/point')
const Range = require('../src/range')
const TextBuffer = require('../src/text-buffer')

describe("TextBuffer IO", () => {
  let buffer

  afterEach(() => {
    if (buffer) buffer.destroy()
  })

  describe('initial load (async)', () => {
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

  describe('initial load (sync)', () => {
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

  describe('save', () => {
    beforeEach((done) => {
      const filePath = temp.openSync('atom').path
      fs.writeFileSync(filePath, 'abc')
      buffer = new TextBuffer({filePath})
      buffer.load().then(done)
    })

    it('does not emit a change event', (done) => {
      buffer.append('def')

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
  })
})

function toPlainObject (value) {
  return JSON.parse(JSON.stringify(value))
}