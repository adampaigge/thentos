{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE FlexibleContexts    #-}

module Thentos.Transaction
where

import Database.PostgreSQL.Simple         (Only(..), FromRow)
import Database.PostgreSQL.Simple.Errors  (ConstraintViolation(UniqueViolation))
import Database.PostgreSQL.Simple.SqlQQ   (sql)

import Thentos.Prelude
import Thentos.Types
import Thentos.Transaction.Core


-- * user

lookupConfirmedUser :: UserId -> ThentosQuery e (UserId, User)
lookupConfirmedUser uid =
    queryT [sql| SELECT name, password, email
                 FROM users
                 WHERE id = ? AND confirmed = true |] (Only uid) >>=
    returnUnique (\(name, pwd, email) -> (uid, User name pwd email))
                 NoSuchUser "lookupConfirmedUser: multiple results"

-- | Lookup any user (whether confirmed or not) by their ID.
lookupAnyUser :: UserId -> ThentosQuery e (UserId, User)
lookupAnyUser uid =
    queryT [sql| SELECT name, password, email
                 FROM users
                 WHERE id = ? |] (Only uid) >>=
    returnUnique (\(name, pwd, email) -> (uid, User name pwd email))
                 NoSuchUser "lookupAnyUser: multiple results"

lookupConfirmedUserByName :: UserName -> ThentosQuery e (UserId, User)
lookupConfirmedUserByName uname =
    queryT [sql| SELECT id, name, password, email
                 FROM users
                 WHERE name = ? AND confirmed = true |] (Only uname) >>=
    returnUnique (\(uid, name, pwd, email) -> (uid, User name pwd email))
                 NoSuchUser "lookupConfirmedUserByName: multiple results"

lookupConfirmedUserByEmail :: UserEmail -> ThentosQuery e (UserId, User)
lookupConfirmedUserByEmail email =
    queryT [sql| SELECT id, name, password
                 FROM users
                 WHERE email = ? AND confirmed = true |] (Only email) >>=
    returnUnique (\(uid, name, pwd) -> (uid, User name pwd email))
                 NoSuchUser "lookupConfirmedUserByEmail: multiple results"

-- | Lookup any user (whether confirmed or not) by their email address.
lookupAnyUserByEmail :: UserEmail -> ThentosQuery e (UserId, User)
lookupAnyUserByEmail email =
    queryT [sql| SELECT id, name, password
                 FROM users
                 WHERE email = ? |] (Only email) >>=
    returnUnique (\(uid, name, pwd) -> (uid, User name pwd email))
                 NoSuchUser "lookupAnyUserByEmail: multiple results"

-- | Add a new user.  The DB will automatically create a new 'UserId' (auto-increment).
addUserPrim :: User -> Bool -> ThentosQuery e UserId
addUserPrim user confirmed =
    queryT [sql| INSERT INTO users (name, password, email, confirmed)
                 VALUES (?, ?, ?, ?)
                 RETURNING id |]
           (user ^. userName, user ^. userPassword, user ^. userEmail, confirmed) >>=
    returnUnique' fromOnly
        (impossible "addUserPrim created user without ID")
        (impossible "addUserPrim created multiple users")

-- | Add a new user and return the new user's 'UserId'.
-- Ensures that user name and email address are unique.
addUser :: User -> ThentosQuery e UserId
addUser user = addUserPrim user True

-- | Add a new unconfirmed user (i.e. one whose email address we haven't confirmed yet).
-- Ensures that user name and email address are unique.
addUnconfirmedUser :: ConfirmationToken -> User -> ThentosQuery e UserId
addUnconfirmedUser token user = do
    uid <- addUserPrim user False
    void $ execT [sql| INSERT INTO user_confirmation_tokens (id, token)
                       VALUES (?, ?) |] (uid, token)
    return uid

finishUserRegistration :: Timeout -> ConfirmationToken -> ThentosQuery e UserId
finishUserRegistration timeout token =
    queryT [sql|
        UPDATE users SET confirmed = true
        FROM user_confirmation_tokens
        WHERE users.id = user_confirmation_tokens.id
            AND timestamp + ? > now()
            AND token = ?;

        DELETE FROM user_confirmation_tokens
        WHERE token = ? AND timestamp + ? > now()
        RETURNING id;
    |] (timeout, token, token, timeout) >>=
    returnUnique fromOnly NoSuchPendingUserConfirmation
                 "finishUserRegistration: repeated user confirmation token"

-- | Add a password reset token.  Return the user whose password this token can change.
addPasswordResetToken :: UserEmail -> PasswordResetToken -> ThentosQuery e User
addPasswordResetToken email token = do
    (uid, user) <- lookupAnyUserByEmail email
    void $ execT [sql| INSERT INTO password_reset_tokens (token, uid)
                VALUES (?, ?) |] (token, uid)
    return user


-- | Change a password with a given password reset token and remove the token.  Also confirms the
-- user's email address if that hasn't happened before.  Throw an error if the token does not
-- exist or has expired.  Returns the ID of the updated user.
resetPassword :: Timeout -> PasswordResetToken -> HashedSecret UserPass -> ThentosQuery e UserId
resetPassword timeout token newPassword = do
    res <- queryT [sql| UPDATE users
                        SET password = ?, confirmed = true
                        FROM password_reset_tokens
                        WHERE password_reset_tokens.timestamp + ? > now()
                        AND users.id = password_reset_tokens.uid
                        AND password_reset_tokens.token = ?
                        RETURNING users.id
                      |] (newPassword, timeout, token)
    void $ execT [sql| DELETE FROM password_reset_tokens WHERE token = ? |] (Only token)
    returnUnique fromOnly NoSuchToken
                 "resetPassword: password reset token exists multiple times" res

addUserEmailChangeRequest :: UserId -> UserEmail -> ConfirmationToken -> ThentosQuery e ()
addUserEmailChangeRequest uid newEmail token = do
    void $ execT [sql| INSERT INTO email_change_tokens (token, uid, new_email)
                VALUES (?, ?, ?) |] (token, uid, newEmail)

-- | Change email with a given token and remove the token.  Throw an error if the token does not
-- exist or has expired.
confirmUserEmailChange :: Timeout -> ConfirmationToken -> ThentosQuery e ()
confirmUserEmailChange timeout token = do
    checkUnique NoSuchToken "confirmUserEmailChange: email change token exists multiple times"
            =<< execT [sql| UPDATE users
                            SET email = email_change_tokens.new_email
                            FROM email_change_tokens
                            WHERE timestamp + ? > now()
                            AND users.id = email_change_tokens.uid
                            AND email_change_tokens.token = ?
                      |] (timeout, token)


-- | Change password. Should only be called once the old password has been
-- verified.
changePassword :: UserId -> HashedSecret UserPass -> ThentosQuery e ()
changePassword uid newpass = do
    checkUnique NoSuchUser "changePassword: unique constraint on id violated"
        =<< execT [sql| UPDATE users SET password = ? WHERE id = ? |]
                (newpass, uid)


-- | Delete user with given 'UserId'.  Throw an error if user does not exist.
deleteUser :: UserId -> ThentosQuery e ()
deleteUser uid =
    execT [sql| DELETE FROM users WHERE id = ? |] (Only uid) >>=
    checkUnique NoSuchUser "deleteUser: unique constraint on id violated"


-- * service

allServiceIds :: ThentosQuery e [ServiceId]
allServiceIds = fromOnly <$$> queryT [sql| SELECT id FROM services |] ()

lookupService :: ServiceId -> ThentosQuery e (ServiceId, Service)
lookupService sid = do
    services <- queryT [sql| SELECT key, owner_user, name, description
                             FROM services
                             WHERE id = ? |] (Only sid)
    service <- returnUnique (\(key, owner, name, desc) -> Service key owner Nothing name desc)
                            NoSuchService "lookupService: multiple results" services
    return (sid, service)

-- | Add new service.
addService ::
    UserId -> ServiceId -> HashedSecret ServiceKey -> ServiceName
    -> ServiceDescription -> ThentosQuery e ()
addService uid sid secret name description = void $
    execT [sql| INSERT INTO services (id, owner_user, name, description, key)
                VALUES (?, ?, ?, ?, ?)
          |] (sid, uid, name, description, secret)

-- | Delete service with given 'ServiceId'.  Throw an error if service does not exist.
deleteService :: ServiceId -> ThentosQuery e ()
deleteService sid = do
    execT [sql| DELETE FROM services WHERE id = ? |] (Only sid) >>=
        checkUnique NoSuchService "deleteService: multiple results"

-- Register a user to grant them access to a service. Throws an error if the user is already
-- registered for the service.
registerUserWithService :: UserId -> ServiceId -> ServiceAccount -> ThentosQuery e ()
registerUserWithService uid sid (ServiceAccount anonymous) = void $
    execT [sql| INSERT INTO user_services (uid, sid, anonymous)
                VALUES (?, ?, ?) |] (uid, sid, anonymous)

-- Unregister a user from accessing a service. No-op if the user was not registered for the
-- service.
unregisterUserFromService :: UserId -> ServiceId -> ThentosQuery e ()
unregisterUserFromService uid sid = void $
    execT [sql| DELETE FROM user_services WHERE uid = ? AND sid = ? |] (uid, sid)


-- * personas, contexts, and groups

-- | Add a new persona to the DB. A persona has a unique name and a user to which it belongs.
-- The 'PersonaId' is assigned by the DB. May throw 'NoSuchUser' or 'PersonaNameAlreadyExists'.
addPersona :: PersonaName -> UserId -> Maybe Uri -> ThentosQuery e Persona
addPersona name uid mExternalUrl =
    queryT [sql| INSERT INTO personas (name, uid, external_url)
                 VALUES (?, ?, ?)
                 RETURNING id |]
           (name, uid, mExternalUrl) >>=
    returnUnique' (\(Only persId) -> Persona persId name uid mExternalUrl) e e
    where e = impossible "addContext didn't return a single ID"

-- | Delete a persona. Throw 'NoSuchPersona' if the persona does not exist in the DB.
deletePersona :: PersonaId -> ThentosQuery e ()
deletePersona persId = do
    execT [sql| DELETE FROM personas WHERE id = ? |] (Only persId) >>=
        checkUnique NoSuchPersona
            "deletePersona: unique constraint on id violated"

-- | Add a new context. The first argument identifies the service to which the context belongs.
-- May throw 'NoSuchService' or 'ContextNameAlreadyExists'.
addContext :: ServiceId -> ContextName -> ContextDescription -> Maybe ProxyUri ->
    ThentosQuery e Context
addContext sid name desc mUrl =
    queryT [sql| INSERT INTO contexts (owner_service, name, description, url)
                 VALUES (?, ?, ?, ?)
                 RETURNING id |]
           (sid, name, desc, mUrl) >>=
    returnUnique' (\(Only cxtId) -> Context cxtId sid name desc mUrl) e e
    where e = impossible "addContext didn't return a single ID"

-- | Delete a context. Throw an error if the context does not exist in the DB.
deleteContext :: ServiceId -> ContextName -> ThentosQuery e ()
deleteContext sid cname = do
    execT [sql| DELETE FROM contexts WHERE owner_service = ? AND name = ? |]
            (sid, cname) >>=
        checkUnique NoSuchContext
            "deleteContext: unique constraint on owner_service + name violated"

-- Retrieve 'ContextId' based on 'ServiceId' and 'ContextName'.
-- Throws 'NoSuchContext' if the combination doesn't exist.
findContextId :: ServiceId -> ContextName -> ThentosQuery e (Maybe ContextId)
findContextId sid cname =
    queryT [sql| SELECT id FROM contexts WHERE owner_service = ? AND name = ? |]
           (sid, cname) >>=
    returnUnique' (Just . fromOnly) (return Nothing)
        (impossible "findContextId: unique constraint on owner_service + name violated")

-- Connect a persona with a context. Throws an error if the persona is already registered for the
-- context or if the user has any *other* persona registered for the context
-- ('MultiplePersonasPerContext'). (As we currently allow only one persona per user and context.)
-- Throws 'NoSuchPersona' or 'NoSuchContext' if one of the arguments doesn't exist.
registerPersonaWithContext :: Persona -> ServiceId -> ContextName -> ThentosQuery e ()
registerPersonaWithContext persona sid cname = do
    cxtId <- findContextId sid cname >>= maybe (throwError NoSuchContext) pure
    -- Check that user has no registered personas for that context yet
    res <- queryT [sql| SELECT count(*)
                        FROM personas pers, personas_per_context pc
                        WHERE pers.id = pc.persona_id AND pers.uid = ? AND pc.context_id = ? |]
                  (persona ^. personaUid, cxtId)
    case res of
        [Only (count :: Int)] -> when (count > 0) . throwError $ MultiplePersonasPerContext
        _ -> impossible "registerPersonaWithContext: count didn't return a single result"
    void $ execT [sql| INSERT INTO personas_per_context (persona_id, context_id)
                       VALUES (?, ?) |] (persona ^. personaId, cxtId)

-- Unregister a persona from accessing a context. No-op if the persona was not registered for the
-- context.
unregisterPersonaFromContext :: PersonaId -> ServiceId -> ContextName -> ThentosQuery e ()
unregisterPersonaFromContext persId sid cname = findContextId sid cname >>=
    mapM_ (\cxtId -> void $ execT
                [sql| DELETE FROM personas_per_context WHERE persona_id = ? AND context_id = ? |]
                (persId, cxtId))

lookupPersonaByUri :: Uri -> ThentosQuery e Persona
lookupPersonaByUri uri =
    queryT [sql| SELECT pers.id, pers.name, pers.uid
                 FROM personas pers
                 WHERE pers.external_url = ? |] (Only uri) >>=
    returnUnique (\(pid, name, uid) -> Persona pid name uid (Just uri))
                 NoSuchPersona "lookupPersonaByUri: multiple results"

-- Find the persona that a user wants to use for a context (if any).
findPersona :: UserId -> ServiceId -> ContextName -> ThentosQuery e (Maybe Persona)
findPersona uid sid cname =
    queryT [sql| SELECT pers.id, pers.name, pers.external_url
                 FROM personas pers, personas_per_context pc, contexts cxt
                 WHERE pers.id = pc.persona_id AND pc.context_id = cxt.id
                       AND pers.uid = ? AND cxt.owner_service = ? AND cxt.name = ? |]
           (uid, sid, cname) >>=
    returnUnique' (\(persId, name, mExternalUrl) -> Just $ Persona persId name uid mExternalUrl)
                  (return Nothing)
                  (error "findPersona: multiple personas per context")

-- List all contexts owned by a service.
contextsForService :: ServiceId -> ThentosQuery e [Context]
contextsForService sid = mkContext <$$>
    queryT [sql| SELECT id, name, description, url FROM contexts WHERE owner_service = ? |]
           (Only sid)
  where
    mkContext (cxtId, name, description, mUrl) = Context cxtId sid name description mUrl

-- | Add a persona to a group. If the persona is already a member of the group, do nothing.
addPersonaToGroup :: PersonaId -> ServiceGroup -> ThentosQuery e ()
addPersonaToGroup pid group = catchViolation catcher' . void $
    execT [sql| INSERT INTO persona_groups (pid, grp) VALUES (?, ?) |] (pid, group)
  where
    catcher' _ (UniqueViolation "persona_groups_pid_grp_key") = return ()
    catcher' e _                                              = throwIO e

-- | Remove a persona from a group. If the persona is not a member of the group, do nothing.
removePersonaFromGroup :: PersonaId -> ServiceGroup -> ThentosQuery e ()
removePersonaFromGroup pid group = void $
    execT [sql| DELETE FROM persona_groups WHERE pid = ? AND grp = ? |] (pid, group)

-- | Add a group (subgroup) to another group (supergroup) so that all members of subgroup will also
-- be considered members of supergroup. If subgroup is already a direct member of supergroup, do
-- nothing. Throws 'GroupMembershipLoop' if adding the relation would cause a loop.
addGroupToGroup :: ServiceGroup -> ServiceGroup -> ThentosQuery e ()
addGroupToGroup subgroup supergroup = do
    -- Find all groups in which supergroup is a member and make sure that subgroup is not one
    -- of them
    res <- queryT [sql| WITH RECURSIVE groups(name) AS (
            SELECT ?
            UNION
            SELECT supergroup FROM group_tree, groups WHERE subgroup = name
        ) SELECT count(*) FROM groups WHERE name = ?
    |] (supergroup, subgroup)
    case res of
        [Only (count :: Int)] ->
            when (count > 0) . throwError $ GroupMembershipLoop subgroup supergroup
        _                     -> impossible "addGroupToGroup: count didn't return a single result"
    catchViolation catcher' . void $
        execT [sql| INSERT INTO group_tree (subgroup, supergroup) VALUES (?, ?) |]
              (subgroup, supergroup)
  where
    catcher' _ (UniqueViolation "group_tree_supergroup_subgroup_key") = return ()
    catcher' e _                                                      = throwIO e

-- | Remove a group (subgroup) from another group (supergroup). If subgroup is not a direct
-- member of supergroup, do nothing.
removeGroupFromGroup :: ServiceGroup -> ServiceGroup -> ThentosQuery e ()
removeGroupFromGroup subgroup supergroup = void $ execT
    [sql| DELETE FROM group_tree WHERE subgroup = ? AND supergroup = ? |] (subgroup, supergroup)

-- | List all groups a persona belongs to, directly or indirectly. If p is a member of g1,
-- g1 is a member of g2, and g2 is a member of g3, [g1, g2, g3] will be returned.
personaGroups :: PersonaId -> ThentosQuery e [ServiceGroup]
personaGroups pid = fromOnly <$$>
    queryT [sql| WITH RECURSIVE groups(name) AS (
            -- Non-recursive term
            SELECT grp FROM persona_groups WHERE pid = ?
            UNION
            -- Recursive term
            SELECT supergroup FROM group_tree, groups WHERE subgroup = name
        ) SELECT name FROM groups ORDER BY name
    |] (Only pid)

-- | List all personas belonging to a group, directly or indirectly. If p1 is a member of g1,
-- p2 a member of g2, and g a supergroup of g1 and g2, then the personas for g are p1 and p2.
personasFromGroup :: ServiceGroup -> ThentosQuery e [PersonaId]
personasFromGroup grp = fromOnly <$$>
    queryT [sql|WITH RECURSIVE subgroups(grp) AS (
                    -- Non-recursive term
                    values(?)
                UNION
                    -- Recursive term
                    SELECT gt.subgroup FROM group_tree gt, subgroups sg WHERE gt.supergroup = sg.grp
                )
                SELECT DISTINCT pg.pid FROM subgroups sg, persona_groups pg WHERE pg.grp = sg.grp
           |] (Only grp)


-- * thentos and service session

-- | Lookup session.  If session does not exist or has expired, throw an error.  If it does exist,
-- bump the expiry time and return session with bumped expiry time.
lookupThentosSession ::
     ThentosSessionToken -> ThentosQuery e (ThentosSessionToken, ThentosSession)
lookupThentosSession token = do
    void $ execT [sql| UPDATE thentos_sessions
                       SET end_ = now()::timestamptz + period
                       WHERE token = ? AND end_ >= now()
                 |] (Only token)
    sess <- queryT [sql| SELECT uid, sid, start, end_, period FROM thentos_sessions
                         WHERE token = ? AND end_ >= now()
                   |] (Only token)
    returnUnique (\(uid, sid, start, end, period) ->
                    (token, ThentosSession (makeAgent uid sid) start end period))
                 NoSuchThentosSession "lookupThentosSession: multiple results" sess

-- | Start a new thentos session. Start time is set to now, end time is calculated based on the
-- specified 'Timeout'. If the agent is a user, this new session is added to their existing
-- sessions. Only confirmed users are allowed to log in; a 'NoSuchUser' error is thrown otherwise.
-- FIXME not implemented: If the agent is a service with an existing session, its session is
-- replaced.
startThentosSession :: ThentosSessionToken -> Agent -> Timeout -> ThentosQuery e ()
startThentosSession tok (UserA uid) period = do
    void $ lookupConfirmedUser uid  -- may throw NoSuchUser
    void $ execT [sql| INSERT INTO thentos_sessions (token, uid, start, end_, period)
                       VALUES (?, ?, now(), now() + ?, ?)
                 |] (tok, uid, period, period)
startThentosSession tok (ServiceA sid) period = void $ execT
    [sql| INSERT INTO thentos_sessions (token, sid, start, end_, period)
          VALUES (?, ?, now(), now() + ?, ?)|]
            (tok, sid, period, period)

-- | End thentos session and all associated service sessions.
-- If thentos session does not exist or has expired, remove it just the same.
--
-- Always call this transaction if you want to clean up a session (e.g., from a garbage collection
-- transaction).  This way in the future, you can replace this transaction easily by one that does
-- not actually destroy the session, but move it to an archive.
endThentosSession :: ThentosSessionToken -> ThentosQuery e ()
endThentosSession tok =
    void $ execT [sql| DELETE FROM thentos_sessions WHERE token = ?
                 |] (Only tok)

-- | Get the names of all services that a given thentos session is signed into
serviceNamesFromThentosSession :: ThentosSessionToken -> ThentosQuery e [ServiceName]
serviceNamesFromThentosSession tok =
    map fromOnly <$> queryT
        [sql| SELECT services.name
              FROM services, service_sessions
              WHERE services.id = service_sessions.service
                  AND service_sessions.thentos_session_token = ? |] (Only tok)

-- | Like 'lookupThentosSession', but for 'ServiceSession'.  Bump both service and associated
-- thentos session.  If the service session is still active, but the associated thentos session has
-- expired, update service sessions expiry time to @now@ and throw 'NoSuchThentosSession'.
lookupServiceSession :: ServiceSessionToken -> ThentosQuery e (ServiceSessionToken, ServiceSession)
lookupServiceSession token =
    queryT [sql| SELECT service, start, end_, period, thentos_session_token, meta
                 FROM service_sessions
                 WHERE token = ? |] (Only token) >>=
    returnUnique (\(service, start, end, period, thentosSessionToken, meta) ->
                     (token, ServiceSession service start end period thentosSessionToken meta))
                 NoSuchServiceSession "lookupServiceSession: multiple sessions with the same token"

-- | Like 'startThentosSession' for service sessions.  Bump associated thentos session.  Throw an
-- error if thentos session lookup fails.  If a service session already exists for the given
-- 'ServiceId', return its token.
startServiceSession ::
    ThentosSessionToken -> ServiceSessionToken -> ServiceId
    -> Timeout -> ThentosQuery e ()
startServiceSession thentosSessionToken token sid timeout =
    void $ execT [sql| INSERT INTO service_sessions
                        (token, thentos_session_token, start, end_, period, service, meta)
                       VALUES (?, ?, now(), now() + ?, ?, ?,
                            (SELECT users.name FROM users, thentos_sessions WHERE
                             users.id = thentos_sessions.uid
                                AND thentos_sessions.token = ?)
                            ) |]
                (token, thentosSessionToken, timeout, timeout, sid, thentosSessionToken)

-- | Like 'endThentosSession' for service sessions (see there).  If thentos session or service
-- session do not exist or have expired, remove the service session just the same, but never thentos
-- session.
endServiceSession :: ServiceSessionToken -> ThentosQuery e ()
endServiceSession token =
    execT [sql| DELETE FROM service_sessions WHERE token = ? |] (Only token)
    >>=
    checkUnique NoSuchServiceSession "endServiceSession: multiple service sessions with same token"


-- * agents and groups

-- | Add a new group to the groups defined for an 'Agent'.  If 'Group' is already assigned to
-- 'Agent', do nothing.
assignGroup :: Agent -> Group -> ThentosQuery e ()
assignGroup agent group = case agent of
    ServiceA sid -> catchViolation catcherS $
        void $ execT [sql| INSERT INTO service_groups (sid, grp)
                           VALUES (?, ?) |] (sid, group)
    UserA uid -> catchViolation catcherU $
         void $ execT [sql| INSERT INTO user_groups (uid, grp)
                           VALUES (?, ?) |] (uid, group)
  where
    catcherS _ (UniqueViolation "service_groups_sid_grp_key") = return ()
    catcherS e _ = throwIO e

    catcherU _ (UniqueViolation "user_groups_uid_grp_key") = return ()
    catcherU e _ = throwIO e

-- | Remove a 'Group' from the groups defined for an 'Agent'.  If 'Group' is not assigned to 'Agent',
-- do nothing.
unassignGroup :: Agent -> Group -> ThentosQuery e ()
unassignGroup agent group = case agent of
    ServiceA sid -> void $ execT
        [sql| DELETE FROM service_groups WHERE sid = ? AND grp = ? |] (sid, group)
    UserA uid  -> do
        void $ execT [sql| DELETE FROM user_groups WHERE uid = ? AND grp = ? |]
                           (uid, group)

-- | All 'Group's of an 'Agent'.  If 'Agent' does not exist or has no groups, return an empty list.
agentGroups :: Agent -> ThentosQuery e [Group]
agentGroups agent = case agent of
    ServiceA sid -> do
        groups <- queryT [sql| SELECT grp FROM service_groups WHERE sid = ? |]
                        (Only sid)
        return $ map fromOnly groups
    UserA uid  -> do
        groups <- queryT [sql| SELECT grp FROM user_groups WHERE uid = ? |] (Only uid)
        return $ map fromOnly groups


-- * Sybil attack prevention

-- | Store the solution to a captcha in the DB. May throw 'CaptchaIdAlreadyExists'.
storeCaptcha :: CaptchaId -> ST -> ThentosQuery e ()
storeCaptcha cid solution = void $
    execT [sql| INSERT INTO captchas (id, solution) VALUES (?, ?) |] (cid, solution)

-- | Submit a solution to a captcha, returning whether or not the solution is correct.
-- Throws 'NoSuchCaptchaId' if the given 'CaptchaId' doesn't exist in the DB (either because it
-- never did or because it was deleted).
solveCaptcha :: CaptchaId -> ST -> ThentosQuery e Bool
solveCaptcha cid solution =
    queryT [sql| SELECT solution FROM captchas WHERE id = ? |] (Only cid) >>=
    returnUnique (\(Only correct) -> solution == correct)
                 NoSuchCaptchaId "solveCaptcha: multiple results"

-- | Delete a captcha and its solution from the DB. Throws 'NoSuchCaptchaId' if the given
-- 'CaptchaId' doesn't exist in the DB (either because it never did or because it was deleted due
-- to garbage collection or a prior call to this action).
deleteCaptcha :: CaptchaId -> ThentosQuery e ()
deleteCaptcha cid =
    execT [sql| DELETE FROM captchas WHERE id = ? |] (Only cid) >>=
    checkUnique NoSuchCaptchaId "deleteCaptcha: multiple results"


-- * garbage collection

-- | Go through "thentos_sessions" table and find all expired sessions.
garbageCollectThentosSessions :: ThentosQuery e ()
garbageCollectThentosSessions = void $ execT [sql|
    DELETE FROM thentos_sessions WHERE end_ < now()
    |] ()

garbageCollectServiceSessions :: ThentosQuery e ()
garbageCollectServiceSessions = void $ execT [sql|
    DELETE FROM service_sessions WHERE end_ < now()
    |] ()

-- | Remove all expired unconfirmed users from db.
garbageCollectUnconfirmedUsers :: Timeout -> ThentosQuery e ()
garbageCollectUnconfirmedUsers timeout = void $ execT [sql|
    DELETE FROM "users" WHERE created < now() - ?::interval AND confirmed = false;
    |] (Only timeout)

-- | Remove all expired password reset requests from db.
garbageCollectPasswordResetTokens :: Timeout -> ThentosQuery e ()
garbageCollectPasswordResetTokens timeout = void $ execT [sql|
    DELETE FROM "password_reset_tokens" WHERE timestamp < now() - ?::interval;
    |] (Only timeout)

-- | Remove all expired email change requests from db.
garbageCollectEmailChangeTokens :: Timeout -> ThentosQuery e ()
garbageCollectEmailChangeTokens timeout = void $ execT [sql|
    DELETE FROM "email_change_tokens" WHERE timestamp < now() - ?::interval;
    |] (Only timeout)

-- | Remove all expired captchas from db.
garbageCollectCaptchas :: Timeout -> ThentosQuery e ()
garbageCollectCaptchas timeout = void $ execT
    [sql| DELETE FROM captchas WHERE timestamp < now() - ?::interval; |] (Only timeout)


-- * helpers

checkUnique :: ThentosError e -> String -> Int64 -> ThentosQuery e ()
checkUnique zero multi n =
    case n of
        0 -> throwError zero
        1 -> return ()
        _ -> impossible multi

returnUnique' :: FromRow r => (r -> v) -> ThentosQuery e v -> ThentosQuery e v -> [r] -> ThentosQuery e v
returnUnique' conv _    _     [res] = return $ conv res
returnUnique' _    zero _     []    = zero
returnUnique' _    _    multi _     = multi

returnUnique :: FromRow r => (r -> v) -> ThentosError e -> String -> [r] -> ThentosQuery e v
returnUnique conv zero multi = returnUnique' conv (throwError zero) (impossible multi)

-- | Throw an error from a situation which (we believe) will never arise.
impossible :: String -> a
impossible msg = error $ "Impossible error: " ++ msg

-- | Given either a UserId or a ServiceId, return an Agent.  Throws an error if not exactly one of
-- the arguments is 'Just' (totality enforced by constraint on `services.owner_{user,service}`).
-- Useful for getting an Agent from the database.
makeAgent :: Maybe UserId -> Maybe ServiceId -> Agent
makeAgent (Just uid) Nothing  = UserA uid
makeAgent Nothing (Just sid) = ServiceA sid
makeAgent _ _ = impossible "makeAgent: invalid arguments"
