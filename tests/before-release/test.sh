#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

USER="tmt-tester"
USER_HOME="/home/$USER"

CONNECT_RUN="/tmp/CONNECT"

BRANCH="${BRANCH:-}"
# Set following to 1 if you are running on release
PRE_RELEASE="${PRE_RELEASE:-0}"

rlJournalStart
    rlPhaseStartSetup

        if [[ $PRE_RELEASE -eq 1 ]]; then
            [[ -z "$BRANCH" ]] && rlDie "Please set BRANCH when running pre-release"
        fi

        rlFileBackup /etc/sudoers
        id $USER &>/dev/null && {
            rlRun "pkill -9 -u $USER" 0,1
            rlRun "loginctl terminate-user $USER" 0,1
            rlRun "userdel -r $USER" 0 "Removing existing user"
        }
        rlRun "useradd $USER"
        rlRun "echo '$USER ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers" 0 "password-less sudo for test user"
        rlRun "chmod 400 /etc/sudoers"
        rlRun "loginctl enable-linger $USER" # start session so /run/ directory is initialized

        # Making sure USER can r/w to the /var/tmp/tmt
        test -d /var/tmp/tmt && rlRun "chown $USER:$USER /var/tmp/tmt"

        # Clone repo
        rlRun "git clone https://github.com/psss/tmt $USER_HOME/tmt"
        rlRun "pushd $USER_HOME/tmt"
        [ -n "$BRANCH" ] && rlRun "git checkout --force '$BRANCH'"
        # Do not "patch" version for pre-release...
        [[ $PRE_RELEASE -ne 1 ]] && rlRun "sed 's/^Version:.*/Version: 9.9.9/' -i tmt.spec"

        # Install tmt
        if make rpm 2> /tmp/stderr; then
            rlPass "make rpm success"
        else
            rlLog "Missing dependencies, trying to install them and then try again"
            rlRun "grep ' is needed by tmt' /tmp/stderr | sed 's/ .*//' | cut -f 2 | xargs dnf install -y"
            rlRun "make rpm"
        fi
        rlRun "find $USER_HOME/tmt/tmp/RPMS -type f -name '*rpm' | xargs dnf install -y"

        # libvirt might not be running
        rlServiceStart "libvirtd"
        rlRun "su -l -c 'virsh -c qemu:///session list' $USER" || rlDie "qemu:///session not working, no point to continue"

        # Tests need VM machine for 'connect'
        # remove possible leftovers
        test -d $CONNECT_RUN && rlRun "rm -rf $CONNECT_RUN"
        test -d /var/tmp/tmt/testcloud && rlRun "rm -rf /var/tmp/tmt/testcloud"


        # Prepare fedora container image (https://tmt.readthedocs.io/en/latest/questions.html#container-package-cache)
        # but make it work with podman run  registry.fedoraproject.org/fedora:latest
        rlRun "su -l -c 'podman run -itd --name fresh fedora' $USER"
        rlRun "su -l -c 'podman exec fresh dnf makecache' $USER"
        rlRun "su -l -c 'podman commit fresh fresh' $USER"
        rlRun "su -l -c 'podman container rm -f fresh' $USER"
        rlRun "su -l -c 'podman tag fresh registry.fedoraproject.org/fedora:latest' $USER"
        rlRun "su -l -c 'podman images' $USER"

        # Prepare fedora VM
        rlRun "su -l -c 'tmt run --rm plans --default provision -h virtual finish' $USER" 0 "Fetch image"
        # Run dnf makecache in each image (should be single one though)
        for qcow in /var/tmp/tmt/testcloud/images/*qcow2; do
            virt-customize -a $qcow --run-command 'dnf makecache'
        done

        rlRun "su -l -c 'tmt run --id $CONNECT_RUN plans --default provision -h virtual' $USER"
        CONNECT_TO=$CONNECT_RUN/plans/default/provision/guests.yaml
        rlAssertExists $CONNECT_TO

        # Patch plans/provision/connect.fmf
        CONNECT_FMF=plans/provision/connect.fmf
        echo 'summary: Connect to a running guest' > $CONNECT_FMF
        echo 'provision:' >> $CONNECT_FMF
        sed '/default:/d' $CONNECT_RUN/plans/default/provision/guests.yaml >> $CONNECT_FMF
        rlLog "$(cat $CONNECT_FMF)"


        # Patch plans/main.fmf
        PLANS_MAIN=plans/main.fmf
        {
            echo "prepare:"
            echo "- name: tmt"
            echo "  how: install"
            echo "  directory: tmp/RPMS/noarch"
        } >> $PLANS_MAIN

        # Delete the plan -> container vs host are not synced so rpms might not be installable
        rlRun 'rm -f plans/install/minimal.fmf'
        rlRun "git diff | cat"
        if [ -z "$PLANS" ]; then
            rlRun "su -l -c 'cd $USER_HOME/tmt; tmt -c how=full plans ls --filter=enabled:true > $USER_HOME/enabled_plans' $USER"
            PLANS="$(echo $(cat $USER_HOME/enabled_plans))"
        fi
    rlPhaseEnd

    for plan in $PLANS; do
        rlPhaseStartTest "Test: $plan"
            RUN="run$(echo $plan | tr '/' '-')"
            # Core of the test runs as $USER, -l should clear all BEAKER_envs.
            rlRun "su -l -c 'cd $USER_HOME/tmt; tmt -c how=full run --id $USER_HOME/$RUN -v plans --name $plan' $USER"

            # Upload file so one can review ASAP
            rlRun "tar czf /tmp/$RUN.tgz $USER_HOME/$RUN"
            rlFileSubmit /tmp/$RUN.tgz && rm -f /tmp/$RUN.tgz
        rlPhaseEnd
    done

    rlPhaseStartCleanup
        rlRun "su -l -c 'tmt run --id $CONNECT_RUN plans --default finish' $USER"
        rlFileRestore
        rlRun "pkill -u $USER" 0,1
        rlRun "loginctl terminate-user $USER" 0,1
        rlRun "userdel -r $USER"
    rlPhaseEnd
rlJournalEnd
