// ==UserScript==
// @name         jira-force-sortorder
// @description  Force jira to sort comments oldest/newest first
// @version      0.1
// @homepage     https://hub.internal.couchbase.com/confluence/display/CR/Improving+Jira+with+Tampermonkey
// @match        https://issues.couchbase.com/*
// @require      https://ajax.googleapis.com/ajax/libs/jquery/3.6.3/jquery.min.js
// @require      https://couchbase.github.io/build-tools/tampermonkey/util/waitForKeyElements.js
// @grant        GM_addStyle
// ==/UserScript==

(function() {
    'use strict';

    // Change this to "newest" to force newest-first.
    let order = "oldest";

    function clickSort() {
      if (document.getElementById("sort-button").title == "Click to view " + order + " first") {
        document.getElementById("sort-button").click();
      }
    }

    waitForKeyElements("#sort-button", clickSort);
})();