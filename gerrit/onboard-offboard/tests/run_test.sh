#!/bin/bash -e

SCRIPT_DIR=$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT

export GERRIT_NOOP_USERIDS="1,2,3"
export GERRIT_NOOP_GROUPS="a,b,c"

bold=$(tput bold)
underline=$(tput smul)
regular=$(tput sgr0)

function alert() {
    cols=$(tput cols)
    clear
    perl -E "say '=' x ${cols}"
    printf "$1\n" "$2"| fold -sw ${cols}
    perl -E "say '=' x ${cols}"
    sleep 2
}

function cleanup() {
    rm -rf container-storage/{data,db,etc,git,index,lib,test*}
    ssh-keygen -R "[localhost]:10002" &>/dev/null
}

function finish() {
    [ "${TEMP_DIR}" != "" ] && rm -rf ${TEMP_DIR}
}

function interactive_setup() {
    docker compose up -d interactive
    docker compose exec interactive cp /bootstrap/gerrit.config /var/gerrit/etc
    alert "${bold}Gerrit configuration${regular}\n\nAccept all defaults until you reach ${underline}${bold}'Use GitHub OAuth provider for Gerrit login'${regular} - you will need to enable this and provide a client id & secret (create an oauth app first at https://github.com/settings/developers)"
    docker compose exec interactive java -jar /var/gerrit/bin/gerrit.war init -d /var/gerrit --delete-caches --install-all-plugins
    docker compose stop interactive
    docker compose rm interactive -f
}

function start_gerrit() {
    docker compose up -d gerrit
}

function check_gerrit_startup() {
    while ! docker compose logs gerrit | grep -e "Gerrit Code Review .* ready"
    do
        echo "Waiting for Gerrit to start up..."
        sleep 5
    done
}

function python_setup() {
    pushd "${TEMP_DIR}"
    python3 -m venv env
    source env/bin/activate
    pip3 install -r "${SCRIPT_DIR}/../requirements.txt"
    popd
}

function ssh_setup() {
    eval `ssh-agent`
    rm -f "${SCRIPT_DIR}/container-storage/test_key*"
    yes | ssh-keygen -b 2048 -t rsa -f "${SCRIPT_DIR}/container-storage/test_key" -q -N ""
    ssh-add "${SCRIPT_DIR}/container-storage/test_key" &>/dev/null
    ssh-keyscan -p 10002 localhost >> ~/.ssh/known_hosts
}

function add_ini_file() {
    cp files/test.ini container-storage
}

function log_in_user() {
    url="http://localhost:10001/login/%2Fq%2Fstatus%3Aopen%2B-is%3Awip"
    alert "${bold}Initial authentication${regular}\n\nA new browser tab will open shortly, leading to %s, this is the initial authentication. Authorize it, close the tab, come back here and hit enter" "${url}"
    sleep 5
    printf "> "
    open "${url}"
    read
}

function create_http_password() {
    url="http://localhost:10001/settings/#HTTPCredentials"
    while grep -q 'token = GERRIT_HTTP_AUTH_TOKEN' container-storage/test.ini
    do
        alert "${bold}Generating an HTTP password${regular}\n\nA new browser tab will open shortly, leading to %s, click 'Generate new password' under HTTP credentials, and paste the generated password into the prompt below" "${url}"
        sleep 5
        open "${url}"
        printf "generated password> "
        read GERRIT_HTTP_AUTH_TOKEN
        GERRIT_HTTP_AUTH_TOKEN=$(printf '%s' "$GERRIT_HTTP_AUTH_TOKEN" | sed -e 's/[\/&]/\\&/g')
        [ "$GERRIT_HTTP_AUTH_TOKEN" != "" ] && sed -i.bak "s/GERRIT_HTTP_AUTH_TOKEN/$GERRIT_HTTP_AUTH_TOKEN/" container-storage/test.ini
    done
}

function add_github_token() {
    url="https://github.com/settings/tokens"
    while grep -q 'token = GITHUB_PERSONAL_ACCESS_TOKEN' container-storage/test.ini
    do
        alert "${bold}Generating a Github personal access token${regular}\n\nA new browser tab will open shortly, leading to %s, click 'Generate new token', give it a sensible name choose a suitable expiry length, and choose the following permissions:\n\n    read:org\n    read:user\n    user:email\n\nOnce created, paste the token below." "${url}"
        sleep 5
        open "${url}"
        printf "github token> "
        read GITHUB_PERSONAL_ACCESS_TOKEN
        GITHUB_PERSONAL_ACCESS_TOKEN=$(printf '%s' "$GITHUB_PERSONAL_ACCESS_TOKEN" | sed -e 's/[\/&]/\\&/g')
        [ "$GITHUB_PERSONAL_ACCESS_TOKEN" != "" ] && sed -i.bak "s/GITHUB_PERSONAL_ACCESS_TOKEN/$GITHUB_PERSONAL_ACCESS_TOKEN/" container-storage/test.ini
    done
}

function get_github_username() {
    while grep -q 'username = GITHUB_USERNAME' container-storage/test.ini
    do
        alert "${bold}Enter your github username when prompted${regular}"
        printf "> "
        read GITHUB_USERNAME
        GITHUB_USERNAME=$(printf '%s' "$GITHUB_USERNAME" | sed -e 's/[\/&]/\\&/g')
        [ "$GITHUB_USERNAME" != "" ] && sed -i.bak "s/GITHUB_USERNAME/$GITHUB_USERNAME/" container-storage/test.ini
    done
}

function add_ssh_key() {
    alert "${bold}Adding ssh key to user account${regular}"
    username=$(grep 'username =' container-storage/test.ini | awk '{print $3}')
    gerrit_token=$(grep 'gerrit_token =' container-storage/test.ini | awk '{print $3}')
    curl -X POST http://localhost:10001/a/accounts/self/sshkeys \
         -u "$username:$gerrit_token" \
         -H "Content-Type: text/plain" \
         -d "$(cat ${SCRIPT_DIR}/container-storage/test_key.pub)" &>/dev/null
}

function add_access_database_capacity() {
    alert "${bold}Adding Access Database capability${regular}\n\nA new window will now open, click 'edit' at the bottom of the page, scroll back to the top and add the 'Access Database' global capability for 'Administrators', scroll back down and click save. Again, come back here and hit enter when done"
    sleep 5
    open "http://localhost:10001/admin/repos/All-Projects,access"
    printf "> "
    read
}

function add_group() {
    alert "${bold}Adding group $1${regular}"
    username=$(grep 'username =' container-storage/test.ini | awk '{print $3}')
    gerrit_token=$(grep 'gerrit_token =' container-storage/test.ini | awk '{print $3}')
    curl -X POST http://localhost:10001/a/groups/$1 \
         -u "$username:$gerrit_token" \
         -H "Content-Type: application/json" \
         -d '{
                "description": "Test group",
                "visible_to_all": true,
                "owner": "Administrators"
            }' &>/dev/null
}

function remove_autoadded_user_from_group() {
    username=$(grep 'username =' container-storage/test.ini | awk '{print $3}')
    gerrit_token=$(grep 'gerrit_token =' container-storage/test.ini | awk '{print $3}')
    alert "${bold}Removing auto-added user $username from group $1${regular}"
    curl -X POST http://localhost:10001/a/groups/$1/members.delete \
         -u "$username:$gerrit_token" \
         -H "Content-Type: application/json" \
         -d "{
                \"members\": [\"$username\"]
            }" &>/dev/null
}

function create_user() {
    alert "${bold}Creating user $1${regular}"
    username=$(grep 'username =' container-storage/test.ini | awk '{print $3}')
    gerrit_token=$(grep 'gerrit_token =' container-storage/test.ini | awk '{print $3}')
    curl -X POST http://localhost:10001/a/accounts/$1 \
         -u "$username:$gerrit_token" \
         -H "Content-Type: application/json" \
         -d "{
            \"name\": \"$1\",
            \"display_name\": \"Test User\",
            \"email\": \"test@example.com\",
            \"groups\": [
                \"$2\"
            ]}" &>/dev/null
}

trap finish EXIT

DRY_RUN=--dry-run

while [[ $# -gt 0 ]]; do
    case $1 in
        -w|--wet)
            unset DRY_RUN
            shift
            ;;
        -g|--group)
            shift
            GERRIT_GROUP="${1}"
            shift
            ;;
        -o|--org)
            shift
            GITHUB_ORG="${1}"
            shift
            ;;
    esac
done

if [ "${GERRIT_GROUP}" = "" -o "${GITHUB_ORG}" = "" ]
then
    echo "ERROR: You must provide a gerrit group name and github organisation name with -g and -o"
    exit
fi

if docker ps | grep tests-interactive-1 &>/dev/null
then
    docker-compose down
fi

if ! docker ps | grep tests-gerrit-1 &>/dev/null
then
    cleanup
    interactive_setup
    start_gerrit
    python_setup
    check_gerrit_startup
    ssh_setup
    add_ini_file
    log_in_user
    create_http_password
    add_github_token
    get_github_username
    add_ssh_key
    add_access_database_capacity
    add_group ${GERRIT_GROUP}
    create_user TestUser ${GERRIT_GROUP}
    remove_autoadded_user_from_group ${GERRIT_GROUP}
    echo
else
    python_setup
fi

eval `ssh-agent` &>/dev/null
ssh-add ${SCRIPT_DIR}/container-storage/test_key &>/dev/null

cd "${SCRIPT_DIR}/.."

alert "Running test..."

python3 app.py --config "${SCRIPT_DIR}/../tests/container-storage/test.ini" ${DRY_RUN} --noop-userids 9999996,9999997 --noop-groups 9999998,9999999 --gerrit-group ${GERRIT_GROUP} --github-org "${GITHUB_ORG}"

if [ "${DRY_RUN}" = "--dry-run" ]
then
    echo
    echo "Dry run was performed, retrigger this script with --wet to test any listed changes are applied correctly"
fi

echo
echo "Run 'docker compose down' when finished to clean up"
