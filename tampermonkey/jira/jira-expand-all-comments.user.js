// ==UserScript==
// @name         jira-expand-all-comments
// @description  Expand all comments in Jira on page load
// @version      0.1
// @homepage     https://hub.internal.couchbase.com/confluence/display/CR/Improving+Jira+with+Tampermonkey
// @match        https://issues.couchbase.com/*
// @require      https://ajax.googleapis.com/ajax/libs/jquery/3.6.3/jquery.min.js
// @require      https://couchbase.github.io/build-tools/tampermonkey/util/waitForKeyElements.js
// @grant        GM_addStyle
// ==/UserScript==

(function() {
    'use strict';

    function clickLoadAll() {
      var loadall = document.querySelector('[data-load-all-message="select to load all"]');
      if (loadall !== null) { loadall.click(); }
    }

    waitForKeyElements(".show-more-tab-items", clickLoadAll);
})();
