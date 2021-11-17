const fs = require('fs');
const path = require('path');
const util = require('util');
const exec = util.promisify(require('child_process').exec);

// Check we're passing in a target license
if (!process.env?.['target_license']) {
    console.log(`Target license unspecified, invoke with e.g:
    target_license=[license file] node app.js [target_path] [--action modify,inject,all(default)] [--optionalhandlers markdown]`)
    process.exit()
}

const q = []
let processes = 0
let repoScanLock = false
const gitRepos = {}
let action = "all"
let optionalHandlers = []
const targetPath = path.resolve(process.argv[2])

for (const [i, arg] of process.argv.entries()) {
    if (i > 0) {
        switch (process.argv[i - 1]?.toLowerCase()) {
            case "--action":
                action = process.argv[i]
                process.argv.splice(i - 1, 2)
                break
            case "--optionalhandlers":
                optionalHandlers = process.argv[i].split(",")
                process.argv.splice(i - 1, 2)
                break
        }
    }
}

// Possible actions to take on a file, we push filenames into results[these]
// and read from them when outputting results - note, the order they appear
// here is the same order the output will appear when execution completes
const actions = ['toobig', 'skipped', 'unhandled', 'excluded', 'ignored', 'modified', 'injected', 'missingCopyright', 'ok']
const results = {}
// When outputting results, the action name is used for the heading, however
// you can override these if we provide labels
const resultLabels = {
    modified: "Existing header modified",
    missingCopyright: "Licensed with no copyright header",
    injected: "New header injected",
}
actions.forEach(a => results[a] = [])

// Number of files to process concurrently
const maxQueueDepth = 10

// Copyright regex patterns to be found + replaced
const oldCopyrightHeaders = [
    "(?!.*\})(\s)*[Cc]op(y|ie)right.*(Couchbase|North[Ss]cale)[,]?( Inc)?[\.]?[ ]*[0-9]*[ ]*[-]*[ ]*([Aa]ll [Rr]ights [Rr]eserved)?[\.]?$",
    "Couchbase CONFIDENTIAL",
    "COUCHBASE LITE ENTERPRISE EDITION",
    "\\(C\\)[ ]*[0-9]{4}[ ]*Jung-Sang Ahn <jungsang.ahn@gmail.com>"
]

// Copyright header to inject. YYYY will be replaced with:
//   - original year (when replacing existing header inc year)
//   - first appearance of file in git log (if new)
const newCopyrightHeader = "copyright YYYY-Present Couchbase, Inc."
const newCopyrightHeaderPattern = "[Cc]opyright [0-9]{4}-Present Couchbase, Inc."

// Patterns to exclude - if we match these patterns, we will
// note that the file should be manually reviewed and take no
// other action
const excludedPatterns = [
    /(?!.*([Cc]ouchbase|North[Ss]cale))[Cc]opyright.*[0-9]{4}.*$/gm,
    /(?!.*([Cc]ouchbase|North[Ss]cale))[Cc]opyright.* by .*$/gm,
    /in the public domain.*$/gm,
    /Licensed to the Apache Software Foundation.*$/gm,
    /License: MIT.*$/gm,
    /COUCHBASE INC. COMMUNITY EDITION LICENSE AGREEMENT.*$/gm,
    /This is Apache 2.0 licensed free software.*$/gm,
    /License: Creative Commons Attribution.*$/gm,
    /The author hereby disclaims copyright to this source code.*$/gm,
    /For license information please see antlr4.js.LICENSE.txt.*$/gm,
    /Released under the MIT license.*$/gm
]

const excludedNames = ['d3.v3.min.js']

const excludedExtensions = [
    "json",
    "map",
    "adm",
    "big",
    "csv",
    "plan",
    "sqlpp",
]

const scriptPath = path.dirname(require.main.filename)

const log = {
    INFO: (str) => console.log(`info: ${str}`),
    ERROR: (str) => console.log(`error: ${str}`),
    CHANGE: (str) => console.log(`change: ${str}`),
    INJECT: (str) => console.log(`inject: ${str}`),
    SKIP: (str) => console.log(`skip: ${str}`),
}

// Helper funcs to manipulate strings
const dirname = (s) => s.split('/').slice(0, -1).join('/')
const filename = (s) => s.split('/').slice(-1)[0]
const extension = (s) => s.indexOf('.') > 0 ? s.split('.').slice(-1)[0] : null
const ltrim = (s) => s.replace(/^\s+/, '')
const rtrim = (s) => s.replace(/\s+$/, '')
// manipulate queue
const queue = file => q.push(file)
const unqueue = file => q.splice(q.indexOf(file), 1)
// sleep
const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms))
// check if a file is text
const isText = async (file) => {
    fileType = await runCmd(`file -bhnNr '${file}'`)
    return fileType.trim == "data" || fileType.indexOf('text') >= 0
}

// Get top level git repo info from a given filename
const gitRepo = async (file) => {
    // ensure only a single gitRepo() call is actually pulling info from git
    // log at once, and anything else just waits for it to finish. Doesn't
    // actually cause any problems if we let them trample each other, but it
    // isn't very efficient
    while (repoScanLock) {
        await sleep(5)
    }
    for (const [k, v] of Object.entries(gitRepos)) {
        if (file.indexOf(k) >= 0) {
            return v
        }
    }
    // the info on that repo isn't cached, so set the lock and fetch it
    repoScanLock = true
    const root = await runCmd(`git rev-parse --show-toplevel`, { cwd: dirname(file) }) + '/'
    const copyrightIgnore = path.join(root, '.copyrightignore')
    let exclusions = []
    if (fs.existsSync(copyrightIgnore)) {
        exclusions = fs.readFileSync(copyrightIgnore, 'utf8').trim().split('\n').map(x => {
            return `${targetPath}/${x.trim()}`
        }).filter(x => x != root)
    }
    const gitRepo = { exclusions, root }
    gitRepos[root] = gitRepo
    repoScanLock = false
    return gitRepo
}

// get year a file was added to a git repo
const getAddYear = async (sourceFile) => {
    const repo = await gitRepo(sourceFile.name)
    const root = repo.root
    const cmd = `git log --pretty=format:\"%as\" -- '${sourceFile.name.replace(root, '')}' | tail -n 1`
    const year = (await runCmd(cmd, { cwd: root })).slice(0, 4)
    return year
}

// Find line breaks used in text - https://stackoverflow.com/a/55661801
function getLineBreakChar(string) {
    const indexOfLF = string.indexOf('\n', 1)
    if (indexOfLF === -1) {
        return string.indexOf('\r') !== -1 ? '\r' : '\n'
    }
    if (string[indexOfLF - 1] === '\r') {
        return '\r\n'
    }
    return '\n'
}

// This script uses a number of (comment style) handlers defined in ${scriptPath}/handlers
function loadHandlers() {
    let handlers = {}
    const handlerFiles = Array.from(fs.readdirSync(path.join(scriptPath, 'handlers'))).filter(f => extension(f) == 'json')
    // We need to unpack our handlers and do some prep to make life easier later
    const allHandlers = handlerFiles.map(file => {
        const handler = {
            // unpack the object
            ...JSON.parse(
                fs.readFileSync(path.join(scriptPath, 'handlers', file), 'utf8')
            ),
            // Give it a style property which is the filename minus .json
            style: file.split('.').slice(0, -1)[0]
        }
        // If we might find shebangs, add a generic shebang pattern to 'after'
        if (handler.shebangs) { handler.after = handler.after ? [...handler.after, "^#!"] : ["^#!"] }
        // Make sure inline is an array containing an empty string if not defined
        handler.inline = handler?.inline ?? ['']
        // strip leading dots from extensions so we can deal with them in a uniform way
        handler.extensions = handler?.extensions?.map(ext => ext.replace(/\.+/, ''))
        // Check if a file is not limited
        handler.allows = (file) => !handler?.limit_to || handler.limit_to.filter(l => file.name.search(l)).length > 0
        // split a line array before and after any handler.after matches
        handler.beforeAndAfter = (lineArray) => {
            let before = [], after
            const Hit = {};
            try {
                lineArray.forEach((el, i) => {
                    if (handler?.after?.some(x => el.search(x) >= 0)) {
                        before = [...lineArray.slice(0, i + 1), '']
                        if (lineArray[i + 1] == '') lineArray = lineArray.slice(1)
                        after = [...lineArray.slice(i + 1)]
                        throw Hit
                    }
                })
            } catch (e) {
                if (e !== Hit) throw(e)
            }
            if (before.length === 0) { before = []; after = lineArray }
            return [before, after]
        }
        return handler
    })

    // if we're passing in optional handlers, we need to make sure they exist
    let missingHandlers = optionalHandlers.filter(x => !allHandlers.some(y => y.style === x))
    if (missingHandlers.length > 0) {
        log.ERROR(`optional handlers not found: ${missingHandlers.join(", ")}`)
        process.exit()
    }

    // convert the array of handlers into an object
    for (const handler of allHandlers) {
        handlers[handler.style] = handler
        if (handler?.enabled == false) {
            if (optionalHandlers.some(x => x.toLowerCase() == handler.style)) {
                handler.enabled = true
            } else {
                if (handler?.names?.length > 0) excludedNames.push(...handler.names)
                if (handler?.extensions?.length > 0) excludedExtensions.push(...handler.extensions)
            }
        }
    }

    log.INFO(`loaded handlers: ${Object.keys(handlers).sort().join(', ')}`)
    log.INFO(`optional handlers: ${optionalHandlers.join(", ")}`)
    return allHandlers.filter(handler => handler?.enabled !== false)
}

// Load all the license files from ${scriptPath}/licenses
function loadLicenses() {
    return Array.from(fs.readdirSync(path.join(scriptPath, 'licenses')))
        .map(file => !file.isDirectory && readSrcFile(path.join(scriptPath, 'licenses', file)))
        .filter(license => license)
}

// Recursively retrieve a list of all the files we potentially want to take action
// on within a given path
async function allFiles(targetPath) {
    let nodes = []
    for (const dirEntry of fs.readdirSync(targetPath)) {
        if (dirEntry != '.git') {
            if (fs.lstatSync(path.join(targetPath, dirEntry)).isDirectory()) {
                nodes = nodes.concat(await allFiles(path.join(targetPath, dirEntry)))
            } else if (!dirEntry.isSymlink) {
                nodes.push(path.join(targetPath, dirEntry))
            }
        }
    }
    return nodes
}

// Read a file and return an object with the name, text, linebreak char, and
// line array (and try to guess the handler)
function readSrcFile(name) {
    try {
        const text = fs.readFileSync(name, 'utf-8')
        const linebreak = getLineBreakChar(text)
        const wrap = parseInt(name.match(".*_wrap_(.*)")?.[1])
        const fn = filename(name)
        const meta = {
            name,
            text,
            wrap,
            filename: fn,
            linebreak,
            lines: text.split(linebreak),
        }
        meta.type = getHandler(meta)
        return meta
    } catch (e) {
        log.ERROR(`reading file: ${e}`)
    }
}

// Run a command and get the output
async function runCmd(cmd, workdir) {
    processes++
    const {
        stdout,
        stderr
    } = await exec(cmd, workdir);
    if (stderr) {
        console.log(stderr)
    }
    processes--
    return stdout.trim()
}

// Try to guess a file handler - we assign weights for filename patterns,
// extensions and shebangs and assume the heaviest won
function getHandler(file) {
    let guesses = {}
    let maxWeight = 0
    for (const [k, v] of Object.entries(handlers)) {
        guesses[k] = 0
        guesses[k] += v?.names?.map(name => file.name.search(`\\/${name}$`) > -1).filter(Boolean).length ?? 0
        guesses[k] += v?.extensions?.map(extension => file.name.search(`\\.${extension}.in$`) > -1 || file.name.search(`\\.${extension}$`) > -1).filter(Boolean).length ?? 0
        guesses[k] += v?.shebangs?.map(shebang => file.lines[0].search(shebang) > -1).filter(Boolean).length ?? 0
        if (guesses[k] > maxWeight) {
            maxWeight = guesses[k]
        }
    }
    if (maxWeight) return Object.keys(guesses).filter(x => guesses[x] == maxWeight)[0]
}

function getLicense(prefixLength) {
    for (license of targetLicenses) {
        if (license.wrap + prefixLength <= 80) {
            return license
        }
    }
    return targetLicenses[targetLicenses.length - 1]
}

// Find a copyright line and return information about it,
// and any identified license beginning on the next 3 lines
function findLicense(text, startLine) {
    let licenseFirstLine
    let licenseLastLine
    let linePrefixes = []
    let author = []
    for (const [i, line] of text.lines.entries()) {
        if (i >= startLine) {
            for (const pattern of oldCopyrightHeaders) {
                const patternPos = line.match(pattern)
                if (patternPos?.index > -1) {
                    for (const l of text.lines.slice(i, i + 10)) {
                        if (l.search(/\b(A|a)uthor\b/) >= 0) {
                            author.push(l)
                        }
                    }
                    const prefix = line.slice(0, patternPos.index)
                    for (license of allLicenses) {
                        for (const [n, l] of text.lines.slice(i, i + 10).entries()) {
                            if (l?.endsWith?.(license.lines[0])) {
                                licenseFirstLine = i + n
                            }
                        }

                        if (licenseFirstLine) {
                            let match = true
                            for (const [j, ll] of license.lines.entries()) {
                                if (!rtrim(text.lines[licenseFirstLine + j])?.endsWith?.(rtrim(ltrim(ll)))) {
                                    match = false
                                    linePrefixes = []
                                    licenseLastLine = null
                                    break
                                } else {
                                    linePrefixes.push(text.lines[licenseFirstLine + j].slice(0, text.lines[licenseFirstLine + j].indexOf(ll)))
                                    licenseLastLine = licenseFirstLine + j
                                }
                            }

                            if (match) {
                                return { index: i, offset: patternPos.index, prefix, linePrefixes, copyrightText: line, license, licenseFirstLine, licenseLastLine, author }
                            }
                        }
                    }
                    return { index: i, offset: patternPos.index, prefix, linePrefixes, copyrightText: line, license, licenseFirstLine: licenseFirstLine ?? i, licenseLastLine: licenseLastLine ?? i }
                }
            }
        }
    }
}

// Check if a license snippet is in the text, and retrieve information about it
function matchLicense(text, startLine = 0) {
    const license = findLicense(text, startLine)
    if (license) {
        return {
            pre: text.lines.slice(0, license.index),  // array of lines before the license
            post: text.lines.slice(license.licenseLastLine + 1),     // array of lines after the license
            copyrightPrefix: license.prefix,          // text which appears before the copyright
            prefix: license?.linePrefixes?.[license?.linePrefixes?.length - 1] ?? license.prefix,      // text which appears at the start of each line
            startLine: license.licenseFirstLine,   // which line the license begins on
            endLine: license.licenseLastLine,      // which line the license ends on
            copyrightOffset: license.offset,  // offset in line that license begins on
            copyrightLine: license.copyrightText,      // original copyright text
            author: license?.author  // author line if present
        }
    }

    return false
}

// Check if a file is to be ignored (either non-text, or matched by an exclusion)
async function isIgnored(file) {
    if (excludedNames.some(x => file.endsWith(x))) {
        return true
    }
    if (excludedExtensions.some(x => x == extension(file))) {
        return true
    }
    if ((await gitRepo(file))?.exclusions?.some(excl => {
        return new RegExp(excl).test(file)
    })) {
        return true
    }
    if (!(await isText(file))) {
        return true
    }
}

// Modify an existing copyright header in place (+/- license snippet)
async function modifyExisting(file, sourceFile) {
    // Try to get year from existing copyright line, or fail and use date file
    // was added to git repo
    const yyyy = sourceFile.match.copyrightLine.match(/\b([0-9]{4})\b/)?.[0] ?? await getAddYear(sourceFile)
    const targetLicense = getLicense(sourceFile.match?.prefix?.length ?? 0)

    // Inject the year into our copyright string and update the file
    const newCopyrightLine = sourceFile.match.copyrightPrefix.slice(-1) === "@" ? newCopyrightHeader : newCopyrightHeader.charAt(0).toUpperCase() + newCopyrightHeader.slice(1)
    sourceFile.match.copyrightLine = `${sourceFile.match.copyrightPrefix}${newCopyrightLine.replace('YYYY', yyyy)}`
    const output = sourceFile.match.pre
        .concat(sourceFile.match.copyrightLine)
        .concat([
            rtrim(sourceFile.match.prefix ?? '') + ltrim(sourceFile.match.copyrightSuffix ?? ''),
            sourceFile?.match?.author?.length > 0 ? sourceFile?.match?.author + sourceFile.linebreak : '___remove___', sourceFile?.match?.author?.length > 0 ? rtrim(sourceFile.match.prefix) : '___remove___',
            ...targetLicense.lines.map(
                (x, i) => x.trim() ? `${sourceFile.match.prefix}${x}` : rtrim(sourceFile.match.prefix) + ltrim(i < targetLicense.lines.length - 1 ? sourceFile.match.startSuffix : sourceFile.match.endSuffix))].filter(x => x !== '___remove___'))
        .concat(sourceFile.match.post)
        .join(sourceFile.linebreak)
    return fs.writeFileSync(`${file}`, output)
}

// Inject a new header into a file that has no copyright header already
async function injectNewHeader(file, sourceFile) {
    let outputLines
    const handler = handlers[sourceFile.type]
    const [sourcePre, sourcePost] = [...handler.beforeAndAfter(sourceFile.lines)]
    const yyyy = await getAddYear(sourceFile)

    if (handler?.block?.open) {
        // Block comment style
        const targetLicense = getLicense(0)
        outputLines = [
            handler.block.open,
            newCopyrightHeader.charAt(0).toUpperCase() + newCopyrightHeader.slice(1).replace('YYYY', yyyy),
            '',
            ...targetLicense.lines,
            handler.block.close
        ]
    } else {
        // Line by line comment style
        const targetLicense = getLicense(handler.inline?.[0]?.length + 1 ?? 0)
        outputLines = [
            `${handler.inline[0]} ${newCopyrightHeader.charAt(0).toUpperCase()}${newCopyrightHeader.slice(1).replace('YYYY', yyyy)}`,
            handler.inline[0],
            ...targetLicense.lines.map(l => `${handler.inline[0]}${l ? ' ' : ''}${l}`),
        ]
    }

    if (sourcePost[0].trim() != '') outputLines.push('')

    return fs.writeFileSync(`${file}`, [
        ...sourcePre,
        ...outputLines,
        ...sourcePost].join(sourceFile.linebreak))
}

// Process a single file (called for every file identified by allFiles())
async function processFile(file) {
    queue(file)
    if (await isIgnored(file)) {
        results.ignored.push(file)
        unqueue(file)
        return false
    }

    // There's too much pattern matching going on, to avoid jobs taking forever
    // we set a reasonable limit. As we're skipping processing these, we
    // also add to .copyrightignore, to prompt for manual review and edit
    if (fs.statSync(file).size > 1000000) {
        results.toobig.push(file)
        unqueue(file)
        return false
    }

    let sourceFile = readSrcFile(file)
    const initialText = sourceFile.text

    if (excludedPatterns.some(x => sourceFile.text.search(x) >= 0)) {
        results.excluded.push(file)
        unqueue(file)
        return false
    }
    let finishedModifying = false
    let modified = false
    let _match
    let _lastMatch
    let i = 0
    while (!finishedModifying) {
        let highEndLine = -1
        i++
        _match = matchLicense(sourceFile, _match?.startLine + 1 || 0)
        if (!_match || (_lastMatch && _match.startLine == _lastMatch.startLine && _match.endLine == _lastMatch.endLine)) {
            finishedModifying = true
        } else if (_match.endLine > highEndLine) {
            modified = true
            prevEndLine = sourceFile?.match?.endLine
            sourceFile.match = _match
            highEndLine = _match.endLine
        }
        _lastMatch = _match
        if (sourceFile.match) {
            if (sourceFile?.match?.copyrightLine?.length > 90) {
                // if if's longer that ~90 chars, there's probably an extra copyright
                // holder in there.
                results.excluded.push(file)
                unqueue(file)
                return false
            } else {
                if (['all', 'modify'].some(x => x == action)) {
                    await modifyExisting(file, sourceFile)
                } else {
                    if (modified == true) {
                        results.skipped.push(file)
                        unqueue(file)
                        return false
                    }
                }
            }
        }
        sourceFile = readSrcFile(file)
    }
    if (modified) {
        if (sourceFile.text == initialText) {
            results.ok.push(file)
        } else {
            results.modified.push(file)
        }
        unqueue(file)
        return false
    } else {
        if (!sourceFile.type) {
            results.unhandled.push(file)
            unqueue(file)
            return false
        } else {
            const targetLicense = getLicense(sourceFile.match?.prefix?.length ?? 0)
            if (sourceFile.text.match(newCopyrightHeaderPattern) && sourceFile.text.match(targetLicense.lines[0] + sourceFile.linebreak)) {
                results.ok.push(file)
                unqueue(file)
            } else if (sourceLicenses.some(lic => sourceFile.text.match(lic.lines[0] + sourceFile.linebreak))) {
                results.missingCopyright.push(file)
                unqueue(file)
            } else if (['all', 'inject'].some(x => x == action)) {
                injectNewHeader(file, sourceFile).then(() => {
                    if (readSrcFile(file).text == initialText) {
                        results.ok.push(file)
                    } else {
                        results.injected.push(file)
                    }
                    unqueue(file)
                })
            } else {
                results.skipped.push(file)
                unqueue(file)
            }
        }
    }
}

function listFiles(action) {
    results[action].length > 0 && console.log(`${resultLabels[action] || action.charAt(0).toUpperCase() + action.slice(1)}:\n${results[action].sort().map(x => "    " + x).join("\n")}`)
}

function showTotals() {
    actions.map(a => console.log(`${a}: ${results[a].length}`))
}

const handlers = loadHandlers()
const allLicenses = loadLicenses()
const sourceLicenses = allLicenses//.filter(s => filename(s.name) != process.env['target_license'])

const targetLicenses = allLicenses.filter(s => {
    return filename(s.name).startsWith(process.env['target_license'])
}).sort((a, b) => {
    return b.wrap - a.wrap
})

function writeCopyrightIgnore() {
    let oldCopyrightIgnores = []
    if (fs.existsSync('.copyrightignore')) {
        oldCopyrightIgnores = fs.readFileSync('.copyrightignore', 'utf8').trim().split('\n')
    }
    if (results.toobig.length > 0) {
        const replace = `^${targetPath}/`;
        const re = new RegExp(replace, "g");
        newCopyrightIgnores = oldCopyrightIgnores.concat(results.toobig.map(x => x.replace(re, "")))
        fs.writeFileSync(`${targetPath}/.copyrightignore`, [...new Set(newCopyrightIgnores)].join("\n"))
    }
}

async function main() {
    // get a listing of all the files in path specified in arg[0]
    console.log("Processing", targetPath)
    const files = await allFiles(targetPath)
    fileList = files.filter(x => !excludedExtensions.includes(extension(x)))
    results['excluded'] = files.filter(x => excludedExtensions.includes(extension(x)))
    const numFiles = fileList.length
    while (fileList.length > 0) {
        if (q.length >= maxQueueDepth || processes >= maxQueueDepth * 2) await sleep(10)
        else {
            const file = fileList.shift()
            try {
                processFile(file)
            } catch (e) {
                log.ERROR(`${file}: ${e}`)
            }
        }
    }
    while (q.length > 0 || processes > 0) {
        await sleep(20)
    }
    log.INFO(`Processed ${numFiles} files in ${targetPath}`)
    showTotals()
    console.log()
    actions.map(listFiles)
    showTotals()
    writeCopyrightIgnore()
    console.log()
}

main()
