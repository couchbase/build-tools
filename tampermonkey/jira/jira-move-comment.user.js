// ==UserScript==
// @name         jira-move-comment
// @description  Moves Jira's "Add comment" button to above comments
// @author       Chris Hillery <ceej@couchbase.com>
// @version      0.1
// @homepage     https://hub.internal.couchbase.com/confluence/display/CR/Improving+Jira+with+Tampermonkey
// @match        https://issues.couchbase.com/*
// ==/UserScript==

(function() {
    'use strict';
    let activity = document.getElementById("activitymodule");
    let parent = document.getElementsByClassName("issue-main-column")[0];
    parent.appendChild(activity);
})();
