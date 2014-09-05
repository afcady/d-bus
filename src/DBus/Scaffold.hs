{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}

-- | TH helpers to build scaffolding from introspection data


module DBus.Scaffold where

import           Control.Applicative
import           Control.Monad
import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import           Data.Monoid
import           Data.Text (Text)
import qualified Data.Text as Text
import           Language.Haskell.TH
import           Language.Haskell.TH.Lib
import           Language.Haskell.TH.Syntax

import           DBus.Introspect
import           DBus.Message
import           DBus.Representable
import           DBus.Types
import           DBus.Property


data MethodDescription = MD { methodObjectPath :: Text
                            , methodInterface :: Text
                            , methodMember :: Text
                            , methodArgTypes :: [DBusType]
                            , methodReturnTypes :: [DBusType]
                            } deriving (Eq, Show)

interfacMethodDescriptions path iface =
    for (iInterfaceMethods iface) $ \m ->
    MD { methodObjectPath = path
       , methodInterface = iInterfaceName iface
       , methodMember = iMethodName m
       , methodArgTypes = iArgumentType
                                <$> filter ((/= Just Out) . iArgumentDirection)
                                (iMethodArguments m)
       , methodReturnTypes = iArgumentType
                             <$> filter ((== Just Out) . iArgumentDirection)
                             (iMethodArguments m)
       }
  where for = flip map

nodeMethodDescriptions path node =
    let ifaceMembers = interfacMethodDescriptions path =<< nodeInterfaces node
        subNodeMembers = nodeSubnodes node >>= \n  ->
            let subPath = path <> "/" <> nodeName n
            in nodeMethodDescriptions subPath n
    in ifaceMembers ++ subNodeMembers


data PropertyDescription = PD { pdObjectPath :: Text
                              , pdInterface :: Text
                              , pdName :: Text
                              , pdType :: DBusType
                              }

interfacPropertyDescriptions path iface =
    for (iInterfaceProperties iface) $ \p ->
    PD { pdObjectPath = path
       , pdInterface = iInterfaceName iface
       , pdName = iPropertyName p
       , pdType = iPropertyType p
       }
  where for = flip map

nodePropertyDescriptions path node =
    let ifaceMembers = interfacPropertyDescriptions path =<< nodeInterfaces node
        subNodeMembers = nodeSubnodes node >>= \n  ->
            let subPath = path <> "/" <> nodeName n
            in nodePropertyDescriptions subPath n
    in ifaceMembers ++ subNodeMembers

liftText t = [|Text.pack $(liftString (Text.unpack  t))|]


promotedListT = foldr (\t ts -> appT (appT promotedConsT t) ts) promotedNilT

arrows :: [TypeQ] -> TypeQ -> TypeQ
arrows = flip $ foldr (\t ts -> appT (appT arrowT t) ts)

tupleType :: [TypeQ] -> TypeQ
tupleType xs = foldl (\ts t -> appT ts t) (tupleT (length xs)) xs

promoteSimpleType t = promotedT (mkName (show t))

promoteDBusType :: DBusType -> TypeQ
promoteDBusType (DBusSimpleType t) = [t|'DBusSimpleType $(promoteSimpleType t)|]
promoteDBusType (TypeArray t) = [t| TypeArray $(promoteDBusType t)|]
promoteDBusType (TypeStruct ts) =
    let ts' = promotedListT $ promoteDBusType <$> ts
    in [t| TypeStruct $ts'|]
promoteDBusType (TypeDict k v) =
    [t| TypeDict $(promoteSimpleType k)
                 $(promoteDBusType v) |]
promoteDBusType (TypeDictEntry k v) =
    [t| TypeDictEntry $(promoteSimpleType k)
                      $(promoteDBusType v) |]
promoteDBusType TypeVariant = [t| TypeVariant |]
promoteDBusType TypeUnit = [t| TypeUnit |]

readIntrospectXml :: FilePath -> Q INode
readIntrospectXml interfaceFile = do
    qAddDependentFile interfaceFile
    xml <- qRunIO $ BS.readFile interfaceFile
    case xmlToNode xml of
        Left e -> error $ "Could not parse introspection XML: " ++ show e
        Right r -> return r

methodFunction :: (MethodDescription -> String) -- ^ Generate names from Method
                                                -- descriptions
               -> Maybe Text -- ^ Just name to fix the entity, Nothing to leave
                             -- it as a parameter
               -> MethodDescription -- ^ The method description to generate a
                                    -- function from
               -> Q [Dec]
methodFunction nameGen mbEntity method = do
    let name = mkName (nameGen method)
    conName <- newName "con"
    argNames <- forM (methodArgTypes method) $ \_ -> newName "x"
    argTypeNames <- forM (methodArgTypes method) $ \_ -> newName "t"
    resTypeName <- newName "r"
    let tyVarBndrs = plainTV <$> (argTypeNames ++ [resTypeName])
        representables = map (\t -> classP ''Representable [varT t])
                             (argTypeNames ++ [resTypeName])
        repTypes = zipWith (\n t -> equalP [t|RepType $(varT n)|] t)
                       (argTypeNames)
                       (promoteDBusType <$> methodArgTypes method)

        resType = case methodReturnTypes method of
            [] -> [t|TypeUnit|]
            [t] -> promoteDBusType t
            _ -> let resTypes = promotedListT
                                  (promoteDBusType <$> methodReturnTypes method)
                 in [t|TypeStruct $resTypes|]
        resConstr = (equalP [t|RepType $(varT resTypeName)|]
                            resType)
        context = representables ++ repTypes ++ [resConstr]
        entityType = case mbEntity of
            Nothing -> [[t|Text|]]
            Just _ -> []
    entityName <- newName "entity"
    let entityVar = case mbEntity of
            Nothing -> [varP entityName]
            Just _ -> []
        entityE = case mbEntity of
            Just e -> liftText e
            Nothing -> varE entityName
        argsE = case argNames of
                  [n] -> varE n
                  _ -> tupE (varE <$> argNames)
    tp <- sigD name (forallT tyVarBndrs (sequence context)
                     (arrows ( entityType
                             ++ (varT <$> argTypeNames)
                             ++ [[t| DBusConnection|]]
                             )
                             [t| IO (Either MethodError $(varT resTypeName))|]))
    fun <- funD name
        [clause ( entityVar ++ map varP argNames ++ [varP conName])
            (normalB [|callMethod
                         $(entityE)
                         (objectPath $(liftText $ methodObjectPath method))
                         $(liftText $ methodInterface method)
                         $(liftText $ methodMember method)
                         $(argsE)
                         []
                         $(varE conName)
                      |])
          []
         ]
    return [tp, fun]

propertyFromDescription :: (PropertyDescription -> String)
                        -> Maybe Text
                        -> PropertyDescription
                        -> Q [Dec]
propertyFromDescription nameGen mbEntity pd = do
    entName <- newName "entity"
    let rp ent = [|RP{ rpEntity = $ent
                     , rpObject = objectPath $(liftText $ pdObjectPath pd)
                     , rpInterface = $(liftText $ pdInterface pd)
                     , rpName = $(liftText $ pdName pd)
                     } |]
        name = mkName $ nameGen pd
        entN = (mkName "entity")
        typeName = mkName "t"

        arg = case mbEntity of
            Nothing -> [[t|Text|]]
            Just _ -> []
        t = promoteDBusType $ pdType pd
    tp <- sigD name $ forallT [plainTV typeName]
                        (sequence [ classP ''Representable [varT typeName]
                                  , equalP [t|RepType $(varT typeName)|] t ])
                        (arrows arg [t|RemoteProperty $(varT typeName)|])
    cl <- case mbEntity of
        Nothing -> funD name [clause [varP entN]
                              (normalB (rp (varE entN))) []]
        Just e -> valD (varP name) (normalB . rp $ liftText e) []

    return [tp, cl]
