{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
module ViewProf.Console where
import Control.Arrow ((&&&))
import Data.Function (on)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe
import qualified Data.List.NonEmpty as NE

import Brick hiding (on)
import Control.Lens
import Data.Set (Set)
import GHC.Prof hiding (Profile)
import Graphics.Vty
import qualified Data.Scientific as Sci
import qualified Data.Set as Set
import qualified Data.Vector as V
import qualified Data.Vector.Algorithms.Merge as Merge
import qualified GHC.Prof as Prof

data Profile n = Profile
  { _profileReport :: Prof.Profile
  , _profileViewStates :: NonEmpty ViewState
  , _profileName :: n
  }

instance Named (Profile n) n where
  getName = _profileName

data ViewState
  = AggregatesView
    { _viewModel :: !(V.Vector Prof.AggregateCostCentre)
    , _viewFocus :: !Int
    }
  | CallSitesView
    { _viewCallee :: !Prof.AggregateCostCentre
    , _viewCallSites :: !(V.Vector (CallSite AggregateCostCentre))
    , _viewFocus :: !Int
    , _viewExpanded :: !(Set Int)
    }

makeLenses ''Profile
makeLenses ''ViewState

data Name
  = ViewportAggregates
  | ViewportCallSites
  deriving (Eq, Ord, Show)

handleProfileEvent :: Profile n -> BrickEvent n e -> EventM n (Next (Profile n))
handleProfileEvent prof@Profile {..} ev = case ev of
  VtyEvent vtyEv -> case vtyEv of
    EvKey key []
      | key `elem` [KEsc, KChar 'q'] -> halt prof
      | key `elem` [KChar 'x'] -> continue $! popView prof
      | key `elem` [KUp, KChar 'k'] -> continue $! moveUp prof
      | key `elem` [KDown, KChar 'j'] -> continue $! moveDown prof
    _ -> case NE.head _profileViewStates of
      AggregatesView {} -> case vtyEv of
        EvKey (KChar 't') [] ->
          continue $! sortCostCentresBy
            (Prof.aggregateCostCentreTime &&& Prof.aggregateCostCentreAlloc)
            prof
        EvKey (KChar 'a') [] ->
          continue $! sortCostCentresBy
            (Prof.aggregateCostCentreAlloc &&& Prof.aggregateCostCentreTime)
            prof
        EvKey key []
          | key `elem` [KEnter] -> continue $! viewCallers prof
        _ -> continue prof
      CallSitesView {} -> case vtyEv of
        EvKey (KChar 't') [] -> continue $! sortCallSitesBy
          (Prof.callSiteContribTime &&& Prof.callSiteContribAlloc)
          prof
        EvKey (KChar 'a') [] -> continue $! sortCallSitesBy
          (Prof.callSiteContribAlloc &&& Prof.callSiteContribTime)
          prof
        _ -> continue prof
  _ -> continue prof
  where
    popView p = case NE.nonEmpty (NE.tail _profileViewStates) of
      Nothing -> p
      Just xs -> p & profileViewStates .~ xs
    moveUp p = p & topView . viewFocus %~ (\i -> max 0 (i - 1))
    moveDown p = p & topView . viewFocus %~ (\i -> min (len - 1) (i + 1))
      where
        len = case p ^. topView of
          AggregatesView {_viewModel} -> V.length _viewModel
          CallSitesView {_viewCallSites} -> V.length _viewCallSites
    sortCostCentresBy key p = p & topView . viewModel
      %~ V.modify (Merge.sortBy (flip compare `on` key))
    sortCallSitesBy key p = p & topView . viewCallSites
      %~ V.modify (Merge.sortBy (flip compare `on` key))
    viewCallers p = fromMaybe p $ do
      let !model = p ^. topView . viewModel
          !idx = p ^. topView . viewFocus
      AggregateCostCentre {..} <- model V.!? idx
      (callee, callers) <- Prof.aggregateCallSites
        aggregateCostCentreName
        aggregateCostCentreModule
        (p ^. profileReport)
      return $! p & profileViewStates %~ NE.cons CallSitesView
        { _viewCallee = callee
        , _viewCallSites = V.fromList callers
        , _viewFocus = 0
        , _viewExpanded = Set.empty
        }

topView :: Lens' (Profile n) ViewState
topView = profileViewStates . lens NE.head (\(_ NE.:| xs) x -> x NE.:| xs)
{-# INLINE topView #-}

profileAttr :: AttrName
profileAttr = "profile"

selectedAttr :: AttrName
selectedAttr = "selected"

drawProfile :: Profile Name -> [Widget Name]
drawProfile prof = do
  viewState <- NE.toList $ prof ^. profileViewStates
  return $ case viewState of
    AggregatesView {..} -> viewport ViewportAggregates Vertical $
      vBox $ V.toList $
        flip V.imap _viewModel $ \i row ->
          let widget = drawAggregateCostCentre row
          in if i == _viewFocus
            then withAttr selectedAttr (visible widget)
            else widget
    CallSitesView {..} -> viewport ViewportCallSites Vertical $
      vBox
        [ drawAggregateCostCentre _viewCallee
        , vBox $ V.toList $ flip V.imap _viewCallSites $ \i row ->
          let widget = drawCallSite _viewCallee row
          in if i == _viewFocus
            then withAttr selectedAttr (visible widget)
            else widget
        ]

drawAggregateCostCentre :: Prof.AggregateCostCentre -> Widget n
drawAggregateCostCentre Prof.AggregateCostCentre {..} = hBox
  [ txt aggregateCostCentreModule
  , txt "."
  , padRight Max $ txt aggregateCostCentreName
  , padRight (Pad 1) $ str (show aggregateCostCentreTime) <+> txt "%"
  , str (show aggregateCostCentreAlloc) <+> txt "%"
  ]

drawCallSite
  :: Prof.AggregateCostCentre
  -> Prof.CallSite Prof.AggregateCostCentre
  -> Widget n
drawCallSite AggregateCostCentre {..} CallSite {..} = hBox
  [ txt $ Prof.aggregateCostCentreModule callSiteCostCentre
  , txt "."
  , padRight Max $ txt $ Prof.aggregateCostCentreName callSiteCostCentre
  , padRight (Pad 1) $ hBox
    [ str $ contribution callSiteContribTime aggregateCostCentreTime
    , txt "% ("
    , str $ show callSiteContribTime
    , txt "%)"
    ]
  , hBox
    [ str $ contribution callSiteContribAlloc aggregateCostCentreAlloc
    , txt "% ("
    , str $ show callSiteContribAlloc
    , txt "%)"
    ]
  ]
  where
    contribution part whole
      | whole == 0 = "0.0"
      | otherwise = Sci.formatScientific Sci.Fixed (Just 1) $
        Sci.fromFloatDigits $
          100 * (Sci.toRealFloat part / Sci.toRealFloat whole :: Double)
